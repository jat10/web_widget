defmodule WebWidgetWeb.PageController do
  use WebWidgetWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
