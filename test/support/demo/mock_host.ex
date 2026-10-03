defmodule WebWidget.MockHost do
  @moduledoc "Development/test host simulator. All asynchronous responses use Adapter.send_event/1."
  use GenServer
  alias WebWidget.Adapter

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def handle_event(event, server \\ __MODULE__), do: GenServer.call(server, {:event, event})

  @impl true
  def init(opts), do: {:ok, %{delay: Keyword.get(opts, :delay, 350)}}

  @impl true
  def handle_call({:event, %{type: "widget.init"} = event}, _from, state) do
    id =
      event.conversation_id ||
        "mock-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    response = %{
      type: "response.widget.initialized",
      widget_id: event.widget_id,
      conversation_id: id,
      user_id: event.user_id
    }

    {:reply, {:ok, response}, state}
  end

  def handle_call({:event, %{type: "conversation.history.request"} = event}, _from, state) do
    conversations = WebWidget.MockHistory.conversations()

    messages =
      case Enum.find(conversations, &(&1.id == event.conversation_id)) do
        %{messages: messages} ->
          messages

        nil ->
          if event.conversation_id == "mock-history", do: hd(conversations).messages, else: []
      end

    payload = %{messages: messages, conversations: conversations}
    {:reply, {:ok, response(event, "response.conversation.history", payload)}, state}
  end

  def handle_call({:event, %{type: type} = event}, _from, state)
      when type in ["message.create", "message.edit"] do
    [first | rest] = scenario(event)

    case deliver(first) do
      :ok ->
        delay =
          if String.downcase(String.trim(event.message.content)) == "slow",
            do: state.delay * 4,
            else: state.delay

        rest
        |> Enum.with_index(1)
        |> Enum.each(fn {response, index} ->
          Process.send_after(self(), {:deliver, response}, index * delay)
        end)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:event, _}, _from, state), do: {:reply, {:error, :unsupported_event}, state}

  @impl true
  def handle_info({:deliver, event}, state) do
    deliver(event)
    {:noreply, state}
  end

  defp deliver(%{type: "response.message.create", payload: payload} = event) do
    Adapter.send_event(%{event | payload: Map.put(payload, :timestamp, DateTime.utc_now())})
  end

  defp deliver(event), do: Adapter.send_event(event)

  defp scenario(event) do
    id = "assistant-" <> event.message.id
    text = String.downcase(String.trim(event.message.content))

    answer =
      if text == "hello",
        do: "Hello! How can I help you today?",
        else:
          "This is a prototype response to “#{event.message.content}”. No live search was performed."

    prefix = [
      response(event, "response.typing", %{active: true}),
      response(event, "response.message.create", %{id: id, content: ""})
    ]

    steps =
      cond do
        text == "hello" ->
          []

        text == "fail" ->
          [
            step(event, id, "search", "started", "Searching knowledge base…"),
            step(
              event,
              id,
              "search",
              "failed",
              "Knowledge-base search failed",
              "Mock tool unavailable."
            )
          ]

        text == "research" ->
          [
            step(event, id, "search", "started", "Searching knowledge base…"),
            step(event, id, "sources", "started", "Checking sources…"),
            step(event, id, "search", "updated", "Reviewing search matches…"),
            step(event, id, "search", "completed", "Knowledge-base search complete"),
            step(
              event,
              id,
              "sources",
              "completed",
              "Sources checked",
              "Two mock sources reviewed."
            )
          ]

        true ->
          [
            step(event, id, "search", "started", "Searching knowledge base…"),
            step(event, id, "search", "updated", "Searching knowledge base…"),
            step(event, id, "search", "completed", "Mock knowledge-base search complete"),
            step(
              event,
              id,
              "result",
              "completed",
              "Search result",
              "A mock result for UI testing.",
              "tool_result"
            )
          ]
      end

    ending =
      if text == "fail" do
        [
          response(event, "response.message.failed", %{
            message_id: id,
            code: "mock_tool_failed",
            message: "Unable to complete this response. Try another message."
          })
        ]
      else
        [
          response(event, "response.message.edit", %{
            id: id,
            content: String.slice(answer, 0, div(String.length(answer), 2))
          }),
          response(event, "response.message.edit", %{id: id, content: answer}),
          response(event, "response.message.complete", %{id: id, content: answer})
        ]
      end

    prefix ++
      steps ++
      Enum.drop(ending, -1) ++
      [response(event, "response.typing", %{active: false}), List.last(ending)]
  end

  defp step(event, id, step_id, state, label, content \\ nil, kind \\ "tool_call"),
    do:
      response(event, "response.message.step", %{
        id: id <> "-" <> step_id,
        message_id: id,
        kind: kind,
        state: state,
        label: label,
        content: content,
        metadata: %{}
      })

  defp response(event, type, payload),
    do: %{
      type: type,
      widget_id: event.widget_id,
      conversation_id: event.conversation_id,
      payload: payload
    }
end
