defmodule WebWidget.TestHost.ForceSSLScopedEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :web_widget
  import WebWidget.Endpoint
  web_widget_socket("/widget", scope: "/channels")
  plug WebWidget.TestHost.ScopedRouter
end
