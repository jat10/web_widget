defmodule WebWidgetWeb.WidgetLiveTest do
  use WebWidgetWeb.ConnCase

  import Phoenix.LiveViewTest

  test "parent context retains only bootstrap fields and accepts identical retries", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    assert has_element?(view, "#widget-state[data-context-received='false']")

    params = %{
      user_id: "user_123",
      prompt_context: "Current page: /billing",
      conversation_id: "conv_123",
      permissions: ["admin"],
      widget_id: "untrusted"
    }

    for _ <- 1..2 do
      render_hook(view, "widget.context", params)
      assert has_element?(view, "#widget-state[data-context-received='true']")
      assert has_element?(view, "#web-widget[data-name='WebWidget'][phx-hook='ReactHook']")

      assert %{
               user_id: "user_123",
               conversation_id: "conv_123",
               prompt_context: "Current page: /billing"
             } == :sys.get_state(view.pid).socket.assigns.parent_context
    end

    assert :sys.get_state(view.pid).socket.assigns.messages == []
  end

  test "optional bootstrap fields support new conversations and string context", %{conn: conn} do
    for params <- [%{user_id: "user_123"}, %{user_id: "user_123", prompt_context: "Billing"}] do
      {:ok, view, _} = live(conn, ~p"/widget/demo")
      render_hook(view, "widget.context", params)

      assert :sys.get_state(view.pid).socket.assigns.parent_context == %{
               user_id: "user_123",
               prompt_context: Map.get(params, :prompt_context),
               conversation_id: nil
             }
    end
  end

  test "malformed context cannot initialize the widget", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")

    for params <- [
          %{},
          %{user_id: nil},
          %{user_id: "  "},
          %{user_id: 123},
          %{user_id: "user_123", conversation_id: " "},
          %{user_id: "user_123", conversation_id: 123},
          %{user_id: "user_123", prompt_context: []},
          %{user_id: "user_123", prompt_context: %{}},
          %{user_id: "user_123", prompt_context: true}
        ] do
      render_hook(view, "widget.context", params)
      assert :sys.get_state(view.pid).socket.assigns.parent_context == nil
    end
  end

  test "context cannot be replaced during the LiveView lifetime", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    params = %{user_id: "user_123", conversation_id: "conv_123", prompt_context: nil}
    render_hook(view, "widget.context", params)

    for replacement <- [
          %{params | user_id: "user_456"},
          %{params | conversation_id: "conv_456"},
          %{params | prompt_context: "Changed"}
        ] do
      render_hook(view, "widget.context", replacement)
      assert :sys.get_state(view.pid).socket.assigns.parent_context == params
    end
  end

  test "initial mount hides the chat and rejects submissions until context arrives", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    assert has_element?(view, "#widget-state[data-mode='launcher']")
    refute has_element?(view, "#web-widget")
    render_hook(view, "widget.submit", %{text: "Not initialized"})
    assert :sys.get_state(view.pid).socket.assigns.pending_reply == nil
    assert has_element?(view, "#widget-state[data-mode='launcher']")
    assert view.pid |> :sys.get_state() |> then(& &1.socket.assigns.messages) == []
  end

  test "first submission preserves user text, shows a step, then completes the mock", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    render_hook(view, "widget.context", %{user_id: "user_123"})
    render_hook(view, "widget.submit", %{text: "  Where can I learn?  "})

    assert has_element?(view, "#widget-state[data-mode='conversation']")
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert [%{role: "user", content: "Where can I learn?"}, assistant] = assigns.messages
    assert assistant.step.type == "response.step"
    assert assistant.step.kind == "tool_call"
    assert assistant.step.status == "running"

    send(view.pid, {:mock_reply, assistant.id})
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert assigns.pending_reply == nil
    assert [user, answer] = assigns.messages
    assert user.content == "Where can I learn?"
    assert answer.content =~ "prototype response to “Where can I learn?”"
    assert answer.step.status == "complete"
  end

  test "subsequent submissions keep the conversation and its history", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    render_hook(view, "widget.context", %{user_id: "user_123"})
    render_hook(view, "widget.submit", %{text: "First question"})
    send(view.pid, {:mock_reply, "assistant-1"})
    render(view)
    render_hook(view, "widget.submit", %{text: "Follow-up"})
    send(view.pid, {:mock_reply, "assistant-2"})

    assert has_element?(view, "#widget-state[data-mode='conversation']")
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

    assert Enum.map(assigns.messages, & &1.id) == [
             "user-1",
             "assistant-1",
             "user-2",
             "assistant-2"
           ]

    assert Enum.at(assigns.messages, 2).content == "Follow-up"
  end

  test "rejects blank, oversized and malformed submissions without expanding", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    render_hook(view, "widget.context", %{user_id: "user_123"})

    for params <- [%{text: "  "}, %{text: String.duplicate("a", 2001)}, %{text: nil}, %{}] do
      render_hook(view, "widget.submit", params)
      assert has_element?(view, "#widget-state[data-mode='launcher']")
    end
  end

  test "rejects concurrent sends and ignores stale mock completions", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/widget/demo")
    render_hook(view, "widget.context", %{user_id: "user_123"})
    render_hook(view, "widget.submit", %{text: "First"})
    render_hook(view, "widget.submit", %{text: "Duplicate"})
    send(view.pid, {:mock_reply, "stale"})
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert length(assigns.messages) == 2
    assert assigns.pending_reply.id == "assistant-1"
  end
end
