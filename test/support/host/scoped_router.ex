defmodule WebWidget.TestHost.ScopedRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import WebWidget.Router

  web_widget("/widget", scope: "/channels/")
  web_widget_api("/channels/widget-api", scope: "/channels")

  # Deliberately stale compiled routes must not serve the scoped runtime.
  web_widget("/widget")
  web_widget_api("/widget-api")

  pipeline :browser do
    plug :fetch_session
  end

  scope "/" do
    pipe_through :browser
    get "/bo-session", WebWidget.TestHost.SessionProbe, []
  end
end
