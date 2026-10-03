defmodule WebWidget.HostRouterTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint WebWidget.TestHost.Endpoint

  setup_all do
    Application.put_env(:web_widget, @endpoint,
      secret_key_base: String.duplicate("host", 16),
      live_view: [signing_salt: "host-live"],
      pubsub_server: WebWidget.PubSub,
      server: false
    )

    start_supervised!(@endpoint)
    on_exit(fn -> Application.delete_env(:web_widget, @endpoint) end)
    :ok
  end

  setup do
    config = %{
      channel_config_id: :host_test,
      sink_mfa: {__MODULE__, :unused, []},
      widgets: [
        %{widget_id: "support", display_name: "Host Support", allowed_origins: []}
      ]
    }

    start_supervised!({WebWidget.Runtime, config})
    :ok
  end

  test "default and custom scoped prefixes render using the host endpoint" do
    for path <- ["/widget/support", "/support/chat/support"] do
      conn = get(build_conn(), path)
      document = LazyHTML.from_document(html_response(conn, 200))
      assert LazyHTML.query(document, "title") |> LazyHTML.text() == "Host Support"
      assert LazyHTML.query(document, "body.zaq-widget-page") |> Enum.count() == 1

      {:ok, view, _} = live(conn)
      assert has_element?(view, "#widget-context[phx-hook='WidgetContext']")
      render_hook(view, "widget.context", %{user_id: "user"})
      assert has_element?(view, "#web-widget[phx-hook='ReactHook']")
      assert :sys.get_state(view.pid).socket.endpoint == @endpoint
      assert :sys.get_state(view.pid).socket.assigns.config.title == "Host Support"
    end
  end

  test "unknown widgets have no hooks and reject context and submissions" do
    {:ok, view, _} = live(build_conn(), "/widget/missing")
    assert has_element?(view, "#widget-unavailable")
    refute has_element?(view, "[phx-hook]")
    render_hook(view, "widget.context", %{user_id: "user"})
    render_hook(view, "widget.submit", %{text: "hello"})
    assert has_element?(view, "#widget-unavailable")
  end

  test "connected mount rechecks availability after the HTTP render" do
    conn = get(build_conn(), "/widget/support")
    stop_supervised!({WebWidget.Runtime, :host_test})
    {:ok, view, _} = live(conn)
    assert has_element?(view, "#widget-unavailable")
    refute has_element?(view, "#widget-context")
  end

  test "layout assets are served by the host endpoint" do
    conn = get(build_conn(), "/widget/support")
    document = LazyHTML.from_document(html_response(conn, 200))

    for {selector, attr, content_type} <- [
          {"script[src]", "src", "javascript"},
          {"link[rel='stylesheet']", "href", "text/css"}
        ] do
      [path] = document |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
      asset = get(build_conn(), path)
      assert byte_size(response(asset, 200)) > 1000

      assert Enum.any?(
               Plug.Conn.get_resp_header(asset, "content-type"),
               &String.contains?(&1, content_type)
             )
    end
  end
end
