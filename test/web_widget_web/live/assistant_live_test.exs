defmodule WebWidgetWeb.AssistantLiveTest do
  use WebWidgetWeb.ConnCase

  import Phoenix.LiveViewTest

  test "mounts the assistant-ui React component", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/assistant")

    assert has_element?(view, "#assistant-ui[phx-update='ignore'][phx-hook]")
  end
end
