# Serve the built browser assets over the real LiveView WebSocket transport.
Application.delete_env(:live_react, :vite_host)

config =
  :web_widget
  |> Application.fetch_env!(WebWidgetWeb.Endpoint)
  |> Keyword.merge(
    server: true,
    watchers: [],
    check_origin: ["//127.0.0.1:4019"],
    http: [ip: {127, 0, 0, 1}, port: 4019]
  )

Application.put_env(:web_widget, WebWidgetWeb.Endpoint, config)
{:ok, _} = Application.ensure_all_started(:web_widget)
