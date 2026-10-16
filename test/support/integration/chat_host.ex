defmodule WebWidget.TestIntegration.ChatHost do
  @moduledoc false
  def new(attrs), do: {:ok, attrs}
  def new(nil, opts), do: {:ok, Map.new(opts)}

  def receive_request(test, request, context: context) do
    send(test, {:shared_request, request, context, self()})

    failure = Process.get(:chat_host_failure)

    result =
      if failure && Map.get(request, :type) == failure do
        response(request, :error, request.conversation_id, %{code: :unavailable})
      else
        dispatch(request, context)
      end

    case Process.get(:chat_host_transform) do
      transform when is_function(transform, 2) -> transform.(request, result)
      _ -> result
    end
  end

  defp dispatch(%{content: "submission rejected"} = request, _context) do
    response(request, :error, request.conversation_id, %{code: :submission_rejected})
  end

  defp dispatch(request, context) do
    case request do
      %{type: :conversation_init, conversation_id: denied}
      when denied in ["foreign", "deleted", "unauthorized"] ->
        response(request, :error, denied, %{code: :conversation_not_found})

      %{type: :conversation_history, conversation_id: "history-failure"} ->
        response(request, :error, "history-failure", %{code: :unavailable})

      %{type: :conversation_init, conversation_id: conversation} ->
        initialize(request, context, conversation)

      %{type: :conversation_history, conversation_id: conversation} ->
        for event <- Process.get(:chat_host_history_events, []), do: publish(context, event)

        response(request, :conversation_history, conversation, %{
          processing: Process.get(:chat_host_processing, :unknown),
          messages: [
            %{
              message_id: "persisted-user",
              position: 1,
              role: "user",
              content: "Saved question",
              provider_sent_at: nil
            },
            %{
              message_id: "persisted-assistant",
              position: 2,
              role: "assistant",
              content: "Saved answer",
              provider_sent_at: nil
            }
          ]
        })

      %{content: "timeout"} ->
        response(request, :error, nil, %{code: :timeout, outcome: :unknown})

      %{content: "rejected"} ->
        response(request, :error, request.conversation_id, %{code: :invalid_message})

      %{content: _} ->
        message(request, context)
    end
  end

  defp initialize(request, context, conversation) do
    binding = delivery(context)
    public = response(request, :widget_initialized, conversation, %{created: false})

    case Process.get(:chat_host_binding, :valid) do
      :missing ->
        public

      :invalid ->
        %{response: public, delivery_binding: %{binding | channel_config_id: -1}}

      :unsubscribable ->
        %{response: public, delivery_binding: %{binding | topic: <<255>>}}

      :changed ->
        %{response: public, delivery_binding: %{binding | topic: binding.topic <> ":changed"}}

      :events ->
        %{response: public, delivery_binding: %{binding | events: %{}}}

      :version ->
        %{response: public, delivery_binding: %{binding | protocol_version: 1}}

      :valid ->
        %{response: public, delivery_binding: binding}

      :legacy ->
        %{
          response: public,
          delivery_binding: %{binding | events: Map.delete(binding.events, :user_message)}
        }
    end
  end

  defp message(%{content: "pre-stream failure: " <> body} = request, context) do
    conversation = request.conversation_id || "conversation-1"
    created = is_nil(request.conversation_id)

    receipt =
      response(
        request,
        if(created, do: :conversation_created, else: :status),
        conversation,
        acceptance(request, created)
      )

    if not Process.get(:chat_host_suppress_user, false) and
         Map.has_key?(context.delivery.events, :user_message),
       do: publish(context, %{receipt | type: :user_message})

    stream = %{receipt | message_id: "assistant-" <> request.request_id}

    for {type, payload} <- [
          {:typing, %{active: true}},
          {:message_create, %{body: ""}},
          {:typing, %{active: false}},
          {:message_failed, %{body: body, error: "PRIVATE_TRACE"}}
        ] do
      publish(context, %{stream | type: type, payload: payload})
    end

    {:ok, receipt}
  end

  defp message(request, context) do
    conversation = request.conversation_id || "conversation-1"
    created = is_nil(request.conversation_id)

    receipt =
      response(
        request,
        if(created, do: :conversation_created, else: :status),
        conversation,
        acceptance(request, created)
      )

    if not Process.get(:chat_host_suppress_user, false) and
         Map.has_key?(context.delivery.events, :user_message),
       do: publish(context, %{receipt | type: :user_message})

    stream = %{receipt | message_id: "assistant-" <> request.request_id}

    for {type, payload} <- [{:typing, %{active: true}}, {:message_create, %{body: ""}}],
        request.content != "no answer" do
      publish(context, %{stream | type: type, payload: payload})
    end

    if request.content == "instant" do
      publish(context, %{
        stream
        | type: :message_complete,
          payload: %{body: "Immediate answer"}
      })
    end

    if request.content == "markdown renewal" do
      Task.start(fn ->
        Process.sleep(250)

        publish(context, %{
          stream
          | type: :message_edit,
            payload: %{body: "## Update\n\n**Partial**"}
        })

        Process.sleep(1_000)

        publish(context, %{
          stream
          | type: :message_complete,
            payload: %{body: "## Update\n\n**Finished**"}
        })
      end)
    end

    {:ok, if(request.content == "no answer", do: Map.delete(receipt, :message_id), else: receipt)}
  end

  def publish(context, response) do
    event = Map.fetch!(context.delivery.events, response.type)

    Phoenix.PubSub.broadcast(
      WebWidget.PubSub,
      context.delivery.topic,
      {:web_response, event, response}
    )
  end

  def delivery(context) do
    %{
      protocol_version: 2,
      consumer: :widget,
      channel_config_id: context.channel_config_id,
      topic: "web_widget:recipient:#{context.channel_config_id}:#{person(context.sender_id)}",
      events: %{
        user_message: "response.user_message",
        typing: "response.typing",
        message_create: "response.message.create",
        message_edit: "response.message.edit",
        message_step: "response.message.step",
        message_complete: "response.message.complete",
        message_failed: "response.message.failed",
        error: "response.error"
      }
    }
  end

  def acceptance(request, created) do
    %{
      accepted: true,
      created: created,
      user_message: %{
        message_id: Ecto.UUID.generate(),
        position: System.unique_integer([:positive, :monotonic]),
        role: "user",
        content: request.content,
        provider_sent_at: nil
      }
    }
  end

  # Deliberately not the sender ID: only this host fixture resolves recipients.
  defp person(sender), do: Base.url_encode64(:crypto.hash(:sha256, sender), padding: false)

  def response(request, type, conversation, payload),
    do: %{
      protocol_version: Process.get(:chat_host_protocol_version, 2),
      type: type,
      request_id: request.request_id,
      conversation_id: conversation,
      message_id:
        if(
          type in [
            :message_create,
            :message_edit,
            :message_step,
            :message_complete,
            :message_failed
          ],
          do: "assistant-" <> request.request_id,
          else: nil
        ),
      payload: payload
    }
end
