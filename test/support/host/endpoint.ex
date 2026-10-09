defmodule WebWidget.TestHost.Endpoint do
  use Phoenix.Endpoint, otp_app: :web_widget

  @session_options [store: :cookie, key: "_host", signing_salt: "host-salt"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug WebWidget.TestHost.Router
end
