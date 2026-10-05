defmodule WebWidgetWeb.PageController do
  use WebWidgetWeb, :controller

  alias WebWidget.Integration.Installation

  def widget_demo(conn, params) do
    origin = URI.to_string(%URI{scheme: to_string(conn.scheme), host: conn.host, port: conn.port})

    case Installation.widget_script(Map.get(params, "widget_id", "demo"), origin) do
      {:ok, script} -> render(conn, :widget_demo, installation_script: script)
      {:error, _} -> conn |> put_status(:bad_request) |> text("Invalid widget installation")
    end
  end
end
