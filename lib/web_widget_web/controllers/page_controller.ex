defmodule WebWidgetWeb.PageController do
  use WebWidgetWeb, :controller

  def widget_demo(conn, _params), do: render(conn, :widget_demo)
end
