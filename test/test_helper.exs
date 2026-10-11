ExUnit.start()

{:ok, _} =
  WebWidget.Standalone.start_link(
    demo: [allowed_domains: ["http://www.example.com"]],
    infrastructure: [session: [partitioned: false]]
  )

Ecto.Adapters.SQL.Sandbox.mode(WebWidget.Repo, :manual)
