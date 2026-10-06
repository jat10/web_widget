defmodule WebWidgetWeb.PageControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  alias WebWidget.Integration.Installation

  test "demo renders the shared installation snippet without a hand-built iframe" do
    for {params, id} <- [
          {%{}, "demo"},
          {%{"widget_id" => "support"}, "support"},
          {%{"widget_id" => "42"}, "42"}
        ] do
      conn = demo(params)
      document = LazyHTML.from_document(html_response(conn, 200))
      assert LazyHTML.query(document, "iframe") |> Enum.empty?()
      scripts = LazyHTML.query(document, "script[data-widget-id][defer]")
      assert Enum.count(scripts) == 1

      assert LazyHTML.attribute(scripts, "src") == [
               "http://www.example.com/web_widget/assets/embed.js"
             ]

      assert LazyHTML.attribute(scripts, "data-widget-id") == [id]
      assert LazyHTML.query(document, "#explore article") |> Enum.count() == 6

      if id == "42" do
        {:ok, snippet} = Installation.script(42, "http://www.example.com")
        assert html_response(conn, 200) =~ snippet
      end
    end
  end

  test "demo rejects malformed route IDs instead of emitting unsafe installation markup" do
    for id <- ["../demo", "demo?x", "demo\" onload=\"alert(1)", ["demo"]] do
      assert response(demo(%{"widget_id" => id}), 400) == "Invalid widget installation"
    end
  end

  defp demo(params) do
    build_conn(:get, "/widget-demo", params)
    |> Plug.Conn.fetch_query_params()
    |> Phoenix.Controller.accepts(["html"])
    |> Plug.Conn.put_private(:phoenix_endpoint, WebWidgetWeb.Endpoint)
    |> Phoenix.Controller.put_root_layout(html: {WebWidgetWeb.Layouts, :root})
    |> WebWidgetWeb.PageController.call(:widget_demo)
  end

  test "API pipeline negotiates JSON and rejects an HTML-only client" do
    conn = build_conn() |> Plug.Conn.put_req_header("accept", "application/json")
    assert Phoenix.Controller.get_format(WebWidgetWeb.Router.api(conn, [])) == "json"

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        build_conn()
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> WebWidgetWeb.Router.api([])
      end

    assert %Phoenix.NotAcceptableError{} = error.reason
  end
end
