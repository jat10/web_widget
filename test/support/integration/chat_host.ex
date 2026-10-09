defmodule WebWidget.TestIntegration.ChatHost do
  @moduledoc false
  def new(attrs), do: {:ok, attrs}
  def new(nil, opts), do: {:ok, Map.new(opts)}

  def receive_request(test, request, context: context) do
    send(test, {:shared_request, request, context, self()})

    failure = Process.get(:chat_host_failure)

    if failure && Map.get(request, :type) == failure do
      response(request, :error, request.conversation_id, %{code: :unavailable})
    else
      dispatch(request, context)
    end
  end

  defp dispatch(request, context) do
    case request do
      %{type: :conversation_init, conversation_id: denied}
      when denied in ["foreign", "deleted", "unauthorized"] ->
        response(request, :error, denied, %{code: :conversation_not_found})

      %{type: :conversation_history, conversation_id: "history-failure"} ->
        response(request, :error, "history-failure", %{code: :unavailable})

      %{type: :conversation_init, conversation_id: conversation} ->
        response(request, :widget_initialized, conversation, %{created: false})

      %{type: :conversation_history, conversation_id: conversation} ->
        response(request, :conversation_history, conversation, %{
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

      %{content: _} ->
        message(request, context)
    end
  end

  defp message(request, context) do
    conversation = request.conversation_id || "conversation-1"
    created = is_nil(request.conversation_id)

    receipt =
      response(
        request,
        if(created, do: :conversation_created, else: :status),
        conversation,
        %{accepted: true, created: created}
      )

    for {type, payload} <- [{:typing, %{active: true}}, {:message_create, %{body: ""}}] do
      publish(context, %{receipt | type: type, payload: payload})
    end

    if request.content == "instant" do
      publish(context, %{
        receipt
        | type: :message_complete,
          payload: %{body: "Immediate answer"}
      })
    end

    if request.content == "markdown renewal" do
      Task.start(fn ->
        Process.sleep(250)

        publish(context, %{
          receipt
          | type: :message_edit,
            payload: %{body: "## Update\n\n**Partial**"}
        })

        Process.sleep(1_000)

        publish(context, %{
          receipt
          | type: :message_complete,
            payload: %{body: "## Update\n\n**Finished**"}
        })
      end)
    end

    {:ok, receipt}
  end

  def publish(context, response) do
    event = Map.fetch!(context.delivery.events, response.type)

    Phoenix.PubSub.broadcast(
      WebWidget.PubSub,
      context.delivery.topic,
      {:web_response, event, response}
    )
  end

  def response(request, type, conversation, payload),
    do: %{
      protocol_version: 1,
      type: type,
      request_id: request.request_id,
      conversation_id: conversation,
      message_id: "assistant-" <> request.request_id,
      payload: payload
    }
end
