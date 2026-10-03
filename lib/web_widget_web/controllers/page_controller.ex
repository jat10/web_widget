defmodule WebWidgetWeb.PageController do
  use WebWidgetWeb, :controller

  def widget_demo(conn, params),
    do: render(conn, :widget_demo, widget_id: Map.get(params, "widget_id", "demo"))
end
