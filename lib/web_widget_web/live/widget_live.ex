defmodule WebWidgetWeb.WidgetLive do
  use WebWidgetWeb, :live_view

  @impl true
  def mount(%{"widget_id" => widget_id}, _session, socket) do
    case WebWidget.Runtime.fetch_widget(widget_id) do
      {:ok, %{allowed_origins: [_ | _]} = widget} ->
        mount_widget(socket, widget)

      _ ->
        {:ok, assign(socket, unavailable: true, page_title: "Widget unavailable")}
    end
  end

  defp mount_widget(socket, widget) do
    {:ok,
     assign(socket,
       widget: true,
       unavailable: false,
       widget_id: widget.widget_id,
       allowed_origins: widget.allowed_origins,
       page_title: widget.display_name,
       parent_context: nil,
       mode: :launcher,
       messages: [],
       pending_reply: nil,
       next_id: 1,
       config: %{
         title: widget.display_name,
         placeholder: "Ask a question…",
         follow_up_placeholder: "Ask a follow-up…",
         max_length: 2000
       }
     )}
  end

  @impl true
  def render(%{unavailable: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} widget>
      <p id="widget-unavailable" role="alert">Widget unavailable.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} widget>
      <div
        id="widget-state"
        data-mode={@mode}
        data-context-received={to_string(@parent_context != nil)}
      >
        <div
          id="widget-context"
          phx-hook="WidgetContext"
          phx-update="ignore"
          data-allowed-origins={Jason.encode!(@allowed_origins)}
        />
        <.react
          :if={@parent_context != nil}
          id="web-widget"
          name="WebWidget"
          ssr={false}
          socket={@socket}
          mode={@mode}
          messages={@messages}
          isRunning={@pending_reply != nil}
          config={@config}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{unavailable: true}} = socket) do
    {:reply, %{ok: false, error: "Widget unavailable."}, socket}
  end

  def handle_event("widget.context", %{"user_id" => user_id} = params, socket) do
    context = %{
      user_id: user_id,
      prompt_context: Map.get(params, "prompt_context"),
      conversation_id: Map.get(params, "conversation_id")
    }

    cond do
      not valid_parent_context?(context) ->
        {:reply, %{ok: false, error: "Invalid widget context."}, socket}

      socket.assigns.parent_context not in [nil, context] ->
        {:reply, %{ok: false, error: "Reload the widget to change context."}, socket}

      true ->
        {:reply, %{ok: true}, assign(socket, :parent_context, context)}
    end
  end

  def handle_event("widget.context", _params, socket) do
    {:reply, %{ok: false, error: "Invalid widget context."}, socket}
  end

  def handle_event("widget.submit", _params, %{assigns: %{parent_context: nil}} = socket) do
    {:reply, %{ok: false, error: "Widget context with user_id is required."}, socket}
  end

  def handle_event("widget.submit", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    cond do
      socket.assigns.pending_reply != nil ->
        {:reply, %{ok: false, error: "Please wait for the current response."}, socket}

      text == "" or String.length(text) > socket.assigns.config.max_length ->
        {:reply, %{ok: false, error: "Enter a message of 1–2000 characters."}, socket}

      true ->
        id = socket.assigns.next_id
        assistant_id = "assistant-#{id}"
        timer = Process.send_after(self(), {:mock_reply, assistant_id}, 700)

        messages =
          socket.assigns.messages ++
            [
              %{id: "user-#{id}", role: "user", content: text},
              %{
                id: assistant_id,
                role: "assistant",
                content: "",
                step: %{
                  type: "response.step",
                  kind: "tool_call",
                  text: "Searching knowledge base…",
                  status: "running"
                }
              }
            ]

        {:reply, %{ok: true},
         assign(socket,
           mode: :conversation,
           messages: messages,
           next_id: id + 1,
           pending_reply: %{id: assistant_id, text: text, timer: timer}
         )}
    end
  end

  def handle_event("widget.submit", _params, socket) do
    {:reply, %{ok: false, error: "Enter a text message."}, socket}
  end

  @impl true
  def handle_info({:mock_reply, id}, %{assigns: %{pending_reply: %{id: id} = pending}} = socket) do
    Process.cancel_timer(pending.timer)

    messages =
      Enum.map(socket.assigns.messages, fn
        %{id: ^id} = message ->
          %{
            message
            | content:
                "This is a prototype response to “#{pending.text}”. No live search was performed.",
              step: %{message.step | status: "complete"}
          }

        message ->
          message
      end)

    {:noreply, assign(socket, messages: messages, pending_reply: nil)}
  end

  def handle_info({:mock_reply, _id}, socket), do: {:noreply, socket}

  defp valid_parent_context?(context) do
    nonblank_string?(context.user_id) and
      (is_nil(context.conversation_id) or nonblank_string?(context.conversation_id)) and
      (is_nil(context.prompt_context) or is_binary(context.prompt_context))
  end

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""
end
