defmodule WebWidget.TestHost.ScopedEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :web_widget

  @session_options [store: :cookie, key: "_host", signing_salt: "host-salt"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  import WebWidget.Endpoint
  web_widget_socket("/channels/widget", scope: "/channels/")

  plug Plug.Session, @session_options
  plug WebWidget.TestHost.ScopedRouter
end
