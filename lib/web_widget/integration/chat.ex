defmodule WebWidget.Integration.Chat do
  @moduledoc false
  alias WebWidget.{Adapter, Runtime}
  alias WebWidget.Conversation.State
  alias WebWidget.Integration.{Diagnostics, InitClaims, Response}

  def open(widget_id, params, page_id \\ nil, requested_id \\ nil, expected_sender \\ nil)

  def open(
        widget_id,
        %{"identity_token" => proof} = params,
        page_id,
        requested_id,
        expected_sender
      )
      when map_size(params) == 1 do
    with {:ok, session} <- Runtime.authenticate(widget_id, proof, page_id),
         true <- expected_sender in [nil, session.sender_id],
         {:ok, monitor} <- Runtime.monitor(session) do
      case initialize_and_subscribe(session, requested_id, id(), session.init) do
        {:ok, chat} ->
          {:ok, Map.put(chat, :monitor, monitor)}

        error ->
          Process.demonitor(monitor, [:flush])
          error
      end
    else
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, :backend_revoked} -> {:error, :backend_revoked}
      _ -> {:error, "Unable to authenticate this widget session."}
    end
  end

  def open(_, _, _, _, _), do: {:error, "Initialization accepts only identity_token."}

  defp initialize_and_subscribe(session, requested, request, params) do
    with {:ok, _, session} <-
           Runtime.initialize(
             %{type: "widget.init", request_id: request, conversation_id: requested, params: %{}},
             session
           ),
         {:ok, subscription} <- Runtime.subscribe(session) do
      case Runtime.subscribe_revocation(session) do
        {:ok, revocation} ->
          initialize_subscribed(session, requested, params, subscription, revocation)

        _ ->
          Adapter.unsubscribe(subscription)
          {:error, "Unable to subscribe to widget revocation."}
      end
    end
  end

  defp initialize_subscribed(session, requested, params, subscription, revocation) do
    with true <- Runtime.authorized?(session),
         {:ok, state, positions} <- history(session, requested),
         true <- Runtime.authorized?(session) do
      generation = make_ref()
      timer = expiration_timer(session, generation)

      {:ok,
       %{
         session: session,
         subscription: subscription,
         revocation_subscription: revocation,
         timer: timer,
         auth_generation: generation,
         conversation_id: requested,
         pending_submission: nil,
         accepted_requests: MapSet.new(),
         streams: %{},
         typing_requests: MapSet.new(),
         recovered_processing: state.typing,
         history_revision: 0,
         state: state,
         positions: positions,
         persisted_refs: %{},
         outcome: nil,
         prompt_context: params.prompt_context,
         blocked: false
       }}
    else
      {:error, :unsupported_protocol_version} ->
        Adapter.unsubscribe(subscription)
        Adapter.unsubscribe(revocation)
        {:error, "Unsupported host protocol version. This widget requires version 2."}

      _ ->
        Adapter.unsubscribe(subscription)
        Adapter.unsubscribe(revocation)
        {:error, "Unable to initialize or restore this conversation."}
    end
  end

  def renew(chat, proof) do
    with {:ok, session} <- Runtime.renew(chat.session, proof) do
      generation = make_ref()
      timer = expiration_timer(session, generation)
      Process.cancel_timer(chat.timer)
      {:ok, %{chat | session: session, timer: timer, auth_generation: generation}}
    end
  end

  def update_context(chat, attrs) when is_map(attrs) do
    with {:ok, context} <-
           InitClaims.normalize(Map.put(attrs, :user_id, chat.session.sender_id)),
         true <- is_nil(chat.pending_submission),
         true <- Runtime.authorized?(chat.session) do
      requested = context.conversation_id

      cond do
        is_nil(requested) and is_nil(chat.conversation_id) and not chat.blocked ->
          {:ok, %{chat | prompt_context: context.prompt_context}}

        is_binary(requested) and requested == chat.conversation_id and not chat.blocked ->
          {:ok, chat}

        is_binary(requested) ->
          resume(chat, requested)

        true ->
          {:error, :invalid_context}
      end
    else
      _ -> {:error, :invalid_context}
    end
  end

  def update_context(_, _), do: {:error, :invalid_context}

  defp resume(chat, requested) do
    request = id()

    with {:ok, _, _} <-
           Runtime.initialize(
             %{type: "widget.init", request_id: request, conversation_id: requested, params: %{}},
             chat.session
           ),
         true <- Runtime.authorized?(chat.session),
         {:ok, state, positions} <- history(chat.session, requested),
         true <- Runtime.authorized?(chat.session) do
      {:ok,
       %{
         chat
         | conversation_id: requested,
           state: state,
           positions: positions,
           prompt_context: nil,
           blocked: false,
           outcome: nil,
           persisted_refs: %{},
           accepted_requests: MapSet.new(),
           streams: %{},
           typing_requests: MapSet.new(),
           recovered_processing: state.typing,
           history_revision: chat.history_revision + 1
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  def authorization_metadata(chat) do
    expiry = chat.session.expires_at

    lead = chat.session.refresh_lead_seconds

    %{
      expires_at: expiry,
      refresh_at: expiry - lead,
      server_time: System.system_time(:second),
      credential_id: chat.session.binding_claims && chat.session.binding_claims.jti
    }
  end

  defp expiration_timer(session, generation) do
    Process.send_after(
      self(),
      {:widget_session_expired, session.topic, generation},
      max(0, session.expires_at * 1000 - System.system_time(:millisecond))
    )
  end

  def submit(%{pending_submission: nil, blocked: false} = chat, text) do
    request = id()
    message = %{id: request, content: text, timestamp: DateTime.to_iso8601(DateTime.utc_now())}
    chat = %{chat | pending_submission: request}

    result =
      Runtime.dispatch(
        %{
          type: "message.create",
          request_id: request,
          conversation_id: chat.conversation_id,
          message: Map.take(message, [:id, :content]),
          timestamp: DateTime.utc_now(),
          channel: "web_widget",
          mode: :async,
          prompt_context: chat.prompt_context
        },
        chat.session
      )

    case result do
      {:ok, receipt} -> accept(chat, receipt, request, message)
      %{type: :error} = error -> reject(chat, error, request)
      _ -> unknown_submission(chat)
    end
  end

  def submit(chat, _),
    do: {:error, chat, "Wait for the submission acknowledgement or restore the conversation."}

  defp accept(chat, receipt, request, message) do
    with true <- Response.correlated?(receipt, request),
         %{conversation_id: conversation, payload: %{accepted: true}} <-
           receipt,
         true <- identifier?(conversation) and is_nil(Map.get(receipt, :message_id)),
         true <- valid_receipt?(chat.conversation_id, receipt),
         true <- Runtime.authorized?(chat.session) do
      {:ok,
       %{
         chat
         | conversation_id: conversation,
           prompt_context: nil,
           pending_submission: nil,
           accepted_requests: MapSet.put(chat.accepted_requests, request),
           state:
             chat.state
             |> State.submit(message)
             |> State.acknowledge(request)
             |> Map.put(:typing, chat.state.typing)
       }}
    else
      _ -> unknown_submission(chat, receipt)
    end
  end

  defp reject(chat, response, request) do
    if Response.correlated?(response, request) and is_nil(Map.get(response, :message_id)) and
         Map.get(response, :conversation_id) in [nil, chat.conversation_id] and
         is_map(Map.get(response, :payload)) and Runtime.authorized?(chat.session) do
      unknown =
        Map.get(response.payload, :outcome) == :unknown or response.payload[:code] == :timeout

      error = Response.error_text(response)

      {:error,
       %{
         chat
         | pending_submission: nil,
           blocked: unknown,
           outcome: if(unknown, do: :unknown),
           state: State.submission_error(chat.state, error)
       }, error}
    else
      unknown_submission(chat, response)
    end
  end

  defp unknown_submission(chat, response \\ nil) do
    error =
      if response &&
           Response.validate_version(response) == {:error, :unsupported_protocol_version},
         do: "Unsupported host protocol version. This widget requires version 2.",
         else: "Submission outcome is unknown. Restore the conversation before sending again."

    {:error,
     %{
       chat
       | pending_submission: nil,
         blocked: true,
         outcome: :unknown,
         state: State.submission_error(chat.state, error)
     }, error}
  end

  def receive_response(chat, event, %{request_id: _} = response),
    do: receive_correlated(chat, event, response)

  def receive_response(chat, _, _), do: chat

  defp receive_correlated(chat, event, response) do
    with true <- Runtime.authorized?(chat.session),
         true <- Response.correlated?(response, response.request_id),
         true <-
           not is_nil(chat.conversation_id) and
             Map.get(response, :conversation_id) == chat.conversation_id,
         true <- consistent_stream?(chat, response),
         true <- consistent_refs?(chat, response),
         {:ok, encoded} <- Response.encode(event, response, chat.session.widget_id) do
      cond do
        persisted?(chat, response) ->
          remember_persisted(chat, response)

        applicable?(chat, response) ->
          Diagnostics.log(:applied, response)
          apply_response(chat, encoded, response)

        true ->
          settle_recovered(chat, response)
      end
    else
      _ ->
        Diagnostics.log(:ignored_validation_or_encoding, response)
        chat
    end
  end

  defp applicable?(_chat, %{type: :typing, payload: %{active: false}}), do: true

  defp applicable?(chat, %{type: :typing, request_id: request}) do
    streams = Enum.filter(Map.values(chat.streams), &(&1.request_id == request))
    streams == [] or Enum.any?(streams, &(&1.status == :running))
  end

  defp applicable?(chat, %{type: :message_create, message_id: message}) do
    identifier?(message) and not Map.has_key?(chat.streams, message) and
      not Enum.any?(chat.state.messages, &(&1.id == message))
  end

  defp applicable?(chat, %{type: type, message_id: message, request_id: request})
       when type in [:message_edit, :message_complete, :message_failed] do
    identifier?(message) and
      (match?(%{request_id: ^request, status: :running}, Map.get(chat.streams, message)) or
         (not Map.has_key?(chat.streams, message) and
            not Enum.any?(chat.state.messages, &(&1.id == message))))
  end

  defp applicable?(chat, %{type: :message_step, message_id: message, request_id: request}),
    do: match?(%{request_id: ^request, status: :running}, Map.get(chat.streams, message))

  defp applicable?(_, _), do: false

  defp apply_response(chat, _encoded, %{type: :typing, request_id: request, payload: payload}) do
    typing =
      if payload.active,
        do: MapSet.put(chat.typing_requests, request),
        else: MapSet.delete(chat.typing_requests, request)

    recovered = chat.recovered_processing and payload.active

    %{
      chat
      | typing_requests: typing,
        recovered_processing: recovered,
        state: %{chat.state | typing: recovered or MapSet.size(typing) > 0}
    }
  end

  defp apply_response(chat, encoded, response) do
    terminal = response.type in [:message_complete, :message_failed]
    status = if terminal, do: :terminal, else: :running

    streams =
      Map.put(chat.streams, response.message_id, %{
        request_id: response.request_id,
        status: status
      })

    typing =
      if terminal,
        do: finish_typing(streams, chat.typing_requests, response.request_id),
        else: chat.typing_requests

    state =
      chat.state
      |> ensure_message(response)
      |> State.apply_event(encoded)
      |> deduplicate_user(response)

    recovered = chat.recovered_processing and not terminal

    %{
      chat
      | streams: streams,
        typing_requests: typing,
        recovered_processing: recovered,
        state: %{state | typing: recovered or MapSet.size(typing) > 0},
        persisted_refs: retain_refs(chat.persisted_refs, response)
    }
  end

  defp ensure_message(state, %{type: type, message_id: message})
       when type in [:message_edit, :message_complete, :message_failed] do
    State.apply_event(state, %{
      type: "response.message.create",
      payload: %{id: message, content: ""}
    })
  end

  defp ensure_message(state, _), do: state

  defp persisted?(chat, %{type: type, message_id: message, payload: payload})
       when is_binary(message) and
              type in [
                :message_create,
                :message_edit,
                :message_step,
                :message_complete,
                :message_failed
              ] do
    persisted = Map.get(payload, :assistant_message_id, message)

    not match?(%{status: :terminal}, Map.get(chat.streams, message)) and
      (Enum.any?(
         chat.state.messages,
         &(&1.role == "assistant" and &1.id == persisted and &1.status == "complete")
       ) or
         Enum.any?(chat.persisted_refs, fn {transport, refs} ->
           transport != message and is_binary(persisted) and
             refs[:assistant_message_id] == persisted
         end))
  end

  defp persisted?(_, _), do: false

  defp remember_persisted(chat, response) do
    terminal = response.type in [:message_complete, :message_failed]

    streams =
      Map.put(chat.streams, response.message_id, %{
        request_id: response.request_id,
        status: :terminal
      })

    typing =
      if terminal,
        do: finish_typing(streams, chat.typing_requests, response.request_id),
        else: chat.typing_requests

    recovered = chat.recovered_processing and not terminal
    persisted = Map.get(response.payload, :assistant_message_id, response.message_id)

    state = %{
      chat.state
      | messages:
          Enum.reject(chat.state.messages, &(&1.id == response.message_id and &1.id != persisted))
    }

    state = deduplicate_user(state, response)

    %{
      chat
      | streams: streams,
        persisted_refs: retain_refs(chat.persisted_refs, response),
        typing_requests: typing,
        recovered_processing: recovered,
        state: %{state | typing: recovered or MapSet.size(typing) > 0}
    }
  end

  defp deduplicate_user(state, %{request_id: request, payload: %{user_message_id: persisted}})
       when is_binary(persisted) and persisted != request do
    if Enum.any?(state.messages, &(&1.id == persisted and &1.role == "user")) do
      %{state | messages: Enum.reject(state.messages, &(&1.id == request and &1.role == "user"))}
    else
      state
    end
  end

  defp deduplicate_user(state, _), do: state

  defp consistent_stream?(_chat, %{type: :typing}), do: true

  defp consistent_stream?(chat, %{message_id: message, request_id: request}) do
    case Map.get(chat.streams, message) do
      nil -> true
      %{request_id: ^request} -> true
      _ -> false
    end
  end

  defp consistent_stream?(_, _), do: true

  defp settle_recovered(chat, %{type: type, message_id: message, request_id: request})
       when type in [:message_complete, :message_failed] do
    if match?(%{request_id: ^request, status: :terminal}, Map.get(chat.streams, message)) do
      typing = finish_typing(chat.streams, chat.typing_requests, request)

      %{
        chat
        | recovered_processing: false,
          typing_requests: typing,
          state: %{chat.state | typing: MapSet.size(typing) > 0}
      }
    else
      chat
    end
  end

  defp settle_recovered(chat, _), do: chat

  defp finish_typing(streams, typing, request) do
    if Enum.any?(Map.values(streams), &(&1.request_id == request and &1.status == :running)),
      do: typing,
      else: MapSet.delete(typing, request)
  end

  defp consistent_refs?(chat, %{message_id: message, payload: payload}) when is_map(payload) do
    previous = Map.get(chat.persisted_refs, message, %{})

    Enum.all?([:assistant_message_id, :user_message_id], fn key ->
      value = Map.get(payload, key)

      (is_nil(value) or identifier?(value)) and
        (is_nil(value) or is_nil(previous[key]) or previous[key] == value)
    end)
  end

  defp consistent_refs?(_, _), do: true

  defp retain_refs(refs, %{message_id: id, payload: payload}) do
    public =
      payload
      |> Map.take([:assistant_message_id, :user_message_id])
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    Map.update(refs, id, public, &Map.merge(&1, public))
  end

  def close(chat) do
    Adapter.unsubscribe(chat.subscription)
    Adapter.unsubscribe(chat.revocation_subscription)
    Process.demonitor(chat.monitor, [:flush])
    Process.cancel_timer(chat.timer)
    :ok
  end

  defp history(_session, nil), do: {:ok, State.new(), []}

  defp history(session, conversation) do
    request = id()

    response =
      Runtime.dispatch(
        %{
          type: "conversation.history.request",
          request_id: request,
          conversation_id: conversation,
          params: %{limit: 50}
        },
        session
      )

    with true <- Response.correlated?(response, request),
         %{conversation_id: ^conversation} <- response,
         {:ok, encoded, positions} <- Response.history(response, session.widget_id) do
      state = State.apply_event(State.new(), encoded)
      {:ok, %{state | typing: response.payload[:processing] == :active}, positions}
    else
      _ -> {:error, :history_unavailable}
    end
  end

  defp valid_receipt?(nil, %{type: :conversation_created, payload: %{created: true}}), do: true

  defp valid_receipt?(id, %{type: :status, conversation_id: id, payload: %{created: false}})
       when not is_nil(id), do: true

  defp valid_receipt?(_, _), do: false

  defp identifier?(id),
    do:
      is_binary(id) and String.valid?(id) and
        String.trim(id) != "" and byte_size(id) <= 255

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
