# Serve the built browser assets over the real LiveView WebSocket transport.
Application.delete_env(:live_react, :vite_host)

config =
  :web_widget
  |> Application.fetch_env!(WebWidgetWeb.Endpoint)
  |> Keyword.merge(
    server: true,
    watchers: [],
    live_reload: [patterns: []],
    check_origin: ["//127.0.0.1:4019"],
    http: [ip: {127, 0, 0, 1}, port: 4019]
  )

Application.put_env(:web_widget, WebWidgetWeb.Endpoint, config)
{:ok, _} = Application.ensure_all_started(:web_widget)

Code.require_file("test/support/host/router.ex")
Code.require_file("test/support/host/endpoint.ex")

Application.put_env(:web_widget, WebWidget.TestHost.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: String.duplicate("host", 16),
  live_view: [signing_salt: "host-live"],
  pubsub_server: WebWidget.PubSub,
  check_origin: ["//127.0.0.1:4020"],
  http: [ip: {127, 0, 0, 1}, port: 4020],
  server: true
)

{:ok, _} = Supervisor.start_child(WebWidget.Supervisor, WebWidget.TestHost.Endpoint)
