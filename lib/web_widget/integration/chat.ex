defmodule WebWidget.Integration.Chat do
  @moduledoc false
  alias WebWidget.{Adapter, Runtime}
  alias WebWidget.Conversation.State
  alias WebWidget.Integration.{Diagnostics, InitClaims, Response, UserMessages}

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
         local_submissions: %{},
         submission_request: nil,
         deferred_events: [],
         acknowledged_submission: nil,
         recovery_conversation_id: nil,
         user_requests: %{},
         message_positions: UserMessages.positions(state.messages, positions),
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
         {:pending, nil} <- {:pending, chat.pending_submission},
         {:authorized, true} <- {:authorized, Runtime.authorized?(chat.session)} do
      requested = context.conversation_id

      cond do
        is_nil(requested) and is_nil(chat.conversation_id) and not chat.blocked ->
          {:ok, %{chat | prompt_context: context.prompt_context}}

        is_binary(requested) and requested == chat.conversation_id and not chat.blocked ->
          {:ok, chat}

        is_binary(requested) ->
          resume(chat, requested)

        true ->
          {:error, :conversation_required}
      end
    else
      {:error, :invalid_init_claims} -> {:error, :invalid_context_fields}
      {:pending, _} -> {:error, :submission_pending}
      {:authorized, false} -> {:error, :session_unauthorized}
    end
  end

  def update_context(_, _), do: {:error, :invalid_context_fields}

  defp resume(chat, requested) do
    request = id()

    with {:ok, _, _} <-
           Runtime.initialize(
             %{type: "widget.init", request_id: request, conversation_id: requested, params: %{}},
             chat.session
           ),
         {:authorized, true} <- {:authorized, Runtime.authorized?(chat.session)},
         {:ok, state, positions} <- history(chat.session, requested),
         {:authorized, true} <- {:authorized, Runtime.authorized?(chat.session)} do
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
           history_revision: chat.history_revision + 1,
           user_requests:
             if(chat.conversation_id == requested, do: chat.user_requests, else: %{}),
           message_positions: UserMessages.positions(state.messages, positions),
           recovery_conversation_id: nil,
           deferred_events: []
       }}
    else
      {:authorized, false} -> {:error, :session_unauthorized}
      {:error, _} = error -> error
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

  def submit(chat, text, submission_id \\ nil)

  def submit(%{pending_submission: nil, blocked: false} = chat, text, submission_id) do
    request = id()
    message = %{id: request, content: text}

    local = %{
      submission_id: submission_id,
      conversation_id: chat.conversation_id,
      status: :pending
    }

    chat = %{
      chat
      | pending_submission: request,
        submission_request: request,
        local_submissions: Map.put(chat.local_submissions, request, local)
    }

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
      {:ok, receipt} -> accept(chat, receipt, request)
      %{type: :error} = error -> reject(chat, error, request)
      _ -> unknown_submission(chat)
    end
  end

  def submit(chat, _, _),
    do: {:error, chat, "Wait for the submission acknowledgement or restore the conversation."}

  defp accept(chat, receipt, request) do
    with true <- Response.correlated?(receipt, request),
         %{conversation_id: conversation, payload: %{accepted: true}} <-
           receipt,
         true <- identifier?(conversation) and is_nil(Map.get(receipt, :message_id)),
         true <- valid_receipt?(chat.conversation_id, receipt),
         true <- Runtime.authorized?(chat.session),
         {:ok, row} <- Response.saved_user(receipt, chat.session.widget_id),
         {:ok, chat} <-
           UserMessages.merge(
             %{chat | conversation_id: conversation, prompt_context: nil},
             row,
             request
           ) do
      {:ok, acknowledge_user(chat, request, row.id)}
    else
      _ -> unknown_submission(chat, receipt)
    end
  end

  defp reject(chat, response, request) do
    unknown = unknown_outcome?(response)

    if valid_rejection?(chat, response, request) and error_conversation?(chat, response, unknown) do
      error = Response.error_text(response)
      chat = mark_submission(chat, if(unknown, do: :unknown, else: :rejected))

      {:error,
       %{
         chat
         | pending_submission: nil,
           blocked: unknown,
           outcome: if(unknown, do: :unknown),
           recovery_conversation_id: if(unknown, do: Map.get(response, :conversation_id)),
           state: State.submission_error(chat.state, error)
       }, error}
    else
      unknown_submission(chat, response)
    end
  end

  defp unknown_outcome?(%{payload: payload}) when is_map(payload),
    do:
      payload[:outcome] == :unknown or payload[:code] in [:timeout, :acknowledgement_unavailable]

  defp unknown_outcome?(_), do: false

  defp valid_rejection?(chat, response, request),
    do:
      Response.correlated?(response, request) and is_nil(Map.get(response, :message_id)) and
        is_map(Map.get(response, :payload)) and Runtime.authorized?(chat.session)

  defp error_conversation?(chat, response, unknown) do
    conversation = Map.get(response, :conversation_id)

    conversation in [nil, chat.conversation_id] or
      (unknown and is_nil(chat.conversation_id) and identifier?(conversation))
  end

  defp unknown_submission(chat, response \\ nil) do
    error =
      if response &&
           Response.validate_version(response) == {:error, :unsupported_protocol_version},
         do: "Unsupported host protocol version. This widget requires version 2.",
         else: "Submission outcome is unknown. Restore the conversation before sending again."

    chat = mark_submission(chat, :unknown)

    {:error,
     %{
       chat
       | pending_submission: nil,
         blocked: true,
         outcome: :unknown,
         state: State.submission_error(chat.state, error)
     }, error}
  end

  defp mark_submission(chat, status) do
    locals =
      Map.update!(chat.local_submissions, chat.pending_submission, &Map.put(&1, :status, status))

    %{chat | local_submissions: locals}
  end

  defp acknowledge_user(chat, request, canonical_id) do
    case chat.local_submissions[request] do
      %{status: status} = local when status in [:pending, :unknown] ->
        chat = %{
          chat
          | local_submissions:
              Map.put(chat.local_submissions, request, %{
                local
                | status: :accepted,
                  conversation_id: chat.conversation_id
              }),
            accepted_requests: MapSet.put(chat.accepted_requests, request)
        }

        if chat.submission_request == request do
          %{
            chat
            | acknowledged_submission: %{
                submission_id: local.submission_id,
                message_id: canonical_id
              },
              pending_submission: nil,
              blocked: false,
              outcome: nil,
              recovery_conversation_id: nil,
              state: %{chat.state | error: nil}
          }
        else
          chat
        end

      _ ->
        chat
    end
  end

  def receive_response(chat, event, %{type: :user_message, request_id: request} = response) do
    with true <- Runtime.authorized?(chat.session),
         "response.user_message" <- event,
         ^event <- Map.get(chat.session.delivery_binding.events, :user_message),
         true <- Response.correlated?(response, request),
         true <- user_conversation?(chat, response),
         {:ok, row} <- Response.saved_user(response, chat.session.widget_id),
         {:ok, updated} <- UserMessages.merge(chat, row, request) do
      updated =
        if is_nil(chat.conversation_id),
          do: %{updated | conversation_id: response.conversation_id, prompt_context: nil},
          else: updated

      updated |> acknowledge_user(request, row.id) |> drain_events()
    else
      _ -> chat
    end
  end

  def receive_response(chat, event, %{request_id: request} = response) do
    if is_nil(chat.conversation_id) and
         match?(%{status: :unknown}, chat.local_submissions[request]) do
      defer_event(chat, event, response)
    else
      receive_correlated(chat, event, response)
    end
  end

  def receive_response(chat, _, _), do: chat

  defp defer_event(chat, event, response) do
    with true <- Runtime.authorized?(chat.session),
         true <- Response.correlated?(response, response.request_id),
         true <- identifier?(Map.get(response, :conversation_id)),
         true <- chat.recovery_conversation_id in [nil, response.conversation_id],
         {:ok, _} <- Response.encode(event, response, chat.session.widget_id),
         true <- response.type != :error do
      %{chat | deferred_events: buffer_event(chat.deferred_events, event, response)}
    else
      _ -> chat
    end
  end

  defp buffer_event(events, event, response) do
    same_message = fn previous ->
      Map.get(previous, :message_id) == Map.get(response, :message_id)
    end

    terminal_seen =
      Enum.any?(events, fn {_, previous} ->
        same_message.(previous) and previous.type in [:message_complete, :message_failed]
      end)

    if terminal_seen do
      events
    else
      retained =
        Enum.reject(events, fn {_, previous} ->
          same_message.(previous) and
            (response.type in [:message_complete, :message_failed] or
               deferred_key(previous) == deferred_key(response))
        end)

      if length(retained) < 128, do: retained ++ [{event, response}], else: events
    end
  end

  defp deferred_key(%{type: :message_step, payload: payload}),
    do: {:message_step, payload[:step_id]}

  defp deferred_key(response), do: response.type

  defp drain_events(chat) do
    events = chat.deferred_events

    Enum.reduce(events, %{chat | deferred_events: []}, fn {event, response}, current ->
      receive_correlated(current, event, response)
    end)
  end

  defp user_conversation?(%{conversation_id: conversation} = chat, %{
         conversation_id: conversation,
         request_id: request
       })
       when is_binary(conversation) do
    case chat.local_submissions[request] do
      %{conversation_id: expected} -> expected in [nil, conversation]
      _ -> true
    end
  end

  defp user_conversation?(%{conversation_id: nil} = chat, %{
         request_id: request,
         payload: %{created: true},
         conversation_id: conversation
       }) do
    identifier?(conversation) and
      match?(%{status: :unknown, conversation_id: nil}, chat.local_submissions[request])
  end

  defp user_conversation?(_, _), do: false

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
    |> UserMessages.order()
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
    not Enum.any?(chat.state.messages, &(&1.id == message and &1.role != "assistant")) and
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

    with {:authorized, true} <- {:authorized, Runtime.authorized?(session)},
         :ok <- Response.validate_command(response, request, conversation, :history),
         {:ok, encoded, positions} <- Response.history(response, session.widget_id) do
      state = State.apply_event(State.new(), encoded)
      {:ok, %{state | typing: response.payload[:processing] == :active}, positions}
    else
      {:authorized, false} -> {:error, :session_unauthorized}
      {:error, :invalid_history} -> {:error, :invalid_history_response}
      {:error, _} = error -> error
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
