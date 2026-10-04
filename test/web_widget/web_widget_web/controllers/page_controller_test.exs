defmodule WebWidgetWeb.PageControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  test "demo page embeds the default widget or the requested widget" do
    for {params, path} <- [
          {%{}, "/widget/demo"},
          {%{"widget_id" => "support"}, "/widget/support"}
        ] do
      conn =
        build_conn(:get, "/widget-demo", params)
        |> Plug.Conn.fetch_query_params()
        |> Phoenix.Controller.accepts(["html"])
        |> Plug.Conn.put_private(:phoenix_endpoint, WebWidgetWeb.Endpoint)
        |> WebWidgetWeb.PageController.call(:widget_demo)

      document = LazyHTML.from_document(html_response(conn, 200))

      assert LazyHTML.attribute(LazyHTML.query(document, "#zaq-widget"), "src") == [
               path
             ]

      assert LazyHTML.query(document, ~s(script[src="/web_widget/assets/embed.js"]))
             |> Enum.count() == 1

      assert LazyHTML.attribute(LazyHTML.query(document, "#zaq-widget"), "title") == [
               "Website assistant"
             ]

      assert LazyHTML.query(document, "#explore article") |> Enum.count() == 6
    end
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
