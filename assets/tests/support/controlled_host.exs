defmodule WebWidget.E2EHost do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def configure(id, config), do: GenServer.call(__MODULE__, {:configure, id, config})
  def inspect_session(id), do: GenServer.call(__MODULE__, {:inspect, id})
  def finish(id, fail), do: GenServer.call(__MODULE__, {:finish, id, fail})
  def handle_event(event), do: GenServer.call(__MODULE__, {:event, event})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:configure, id, config}, _, state) do
    session = %{
      reject: config["reject"],
      hold: config["hold"] || false,
      step_kind: config["step_kind"] || "tool_call",
      partial: Map.get(config, "partial", "Partial reply"),
      answer: config["answer"] || "Controlled host reply",
      history:
        Enum.map(config["history"] || [], fn message ->
          %{id: message["id"], role: message["role"], content: message["content"]}
        end),
      messages: [],
      events: [],
      pending: nil
    }

    {:reply, :ok, Map.put(state, id, session)}
  end

  def handle_call({:inspect, id}, _, state) do
    {:reply, Map.take(Map.fetch!(state, id), [:events, :messages]), state}
  end

  def handle_call({:finish, id, fail}, _, state) do
    session = Map.fetch!(state, id)
    session = complete(session, fail)
    {:reply, :ok, Map.put(state, id, session)}
  end

  def handle_call({:event, event}, _, state) do
    session = Map.fetch!(state, event.user_id)
    session = %{session | events: session.events ++ [event]}

    {reply, session} =
      if session.reject == event.type do
        {{:error, :test_rejection}, %{session | reject: nil}}
      else
        accept(event, session)
      end

    {:reply, reply, Map.put(state, event.user_id, session)}
  end

  defp accept(%{type: "widget.init"} = event, session) do
    reply = %{
      type: "response.widget.initialized",
      widget_id: event.widget_id,
      user_id: event.user_id,
      conversation_id: event.conversation_id || "conversation-#{event.user_id}"
    }

    {{:ok, reply}, session}
  end

  defp accept(%{type: "conversation.history.request"} = event, session) do
    messages = session.history ++ session.messages

    reply = %{
      type: "response.conversation.history",
      widget_id: event.widget_id,
      conversation_id: event.conversation_id,
      payload: %{
        messages: messages,
        conversations: [
          %{id: event.conversation_id, title: "Current chat", messages: messages},
          %{id: "other-#{event.user_id}", title: "Other chat", messages: []}
        ]
      }
    }

    {{:ok, reply}, session}
  end

  defp accept(%{type: "message.create"} = event, session) do
    id = "answer-#{event.message.id}"
    emit(event, "response.typing", %{active: true})
    emit(event, "response.message.create", %{id: id, content: ""})

    if session.step_kind != "none" do
      emit(event, "response.message.step", %{
        id: "step-#{id}",
        message_id: id,
        kind: session.step_kind,
        state: "started",
        label: "Controlled activity"
      })
    end

    emit(event, "response.message.edit", %{id: id, content: session.partial})
    message = Map.put(event.message, :role, "user")
    session = %{session | messages: session.messages ++ [message], pending: event}
    {:ok, if(session.hold, do: session, else: complete(session, false))}
  end

  defp complete(%{pending: event} = session, fail) when not is_nil(event) do
    id = "answer-#{event.message.id}"
    emit(event, "response.typing", %{active: false})

    if fail do
      emit(event, "response.message.failed", %{
        message_id: id,
        code: "test_failure",
        message: "Controlled failure"
      })

      %{session | pending: nil}
    else
      emit(event, "response.message.complete", %{id: id, content: session.answer})
      message = %{id: id, role: "assistant", content: session.answer}
      %{session | messages: session.messages ++ [message], pending: nil}
    end
  end

  defp complete(session, _), do: session

  defp emit(event, type, payload) do
    :ok =
      WebWidget.Adapter.send_event(%{
        type: type,
        widget_id: event.widget_id,
        conversation_id: event.conversation_id,
        payload: payload
      })
  end
end
