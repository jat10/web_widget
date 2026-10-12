# A separate singleton generation exercises the same compiled/process scope.
Application.delete_env(:live_react, :vite_host)
{:ok, _} = Application.ensure_all_started(:web_widget)
Code.require_file("test/support/host/session_probe.ex")
Code.require_file("test/support/host/scoped_router.ex")
Code.require_file("test/support/host/scoped_endpoint.ex")
Code.require_file("test/support/host/tls_proxy.ex")

dir = Path.join(System.tmp_dir!(), "web-widget-scope-tls-#{System.pid()}")
File.mkdir_p!(dir)
{cert, key, ca} = WebWidget.TestHost.TLSProxy.certificates(dir)
endpoint = WebWidget.TestHost.ScopedEndpoint
Application.put_env(:web_widget, endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", scheme: "https", port: 4023],
  secret_key_base: String.duplicate("host", 16),
  live_view: [signing_salt: "host-live"], pubsub_server: WebWidget.PubSub,
  check_origin: ["https://localhost:4023"],
  http: [ip: {127, 0, 0, 1}, port: 4024], server: true)

{:ok, specs} = WebWidget.HostAdapter.infrastructure_child_specs(
  pubsub_server: WebWidget.PubSub, scope: "/channels",
  transport: [endpoint: endpoint], token_url: "/scoped-identity",
  proxy: [trusted_proxies: [{127, 0, 0, 1}], public_origin: "https://localhost:4023"])
{:ok, _} = Supervisor.start_link(
  [{Phoenix.PubSub, name: WebWidget.PubSub}] ++ specs ++ [endpoint],
  strategy: :one_for_one, name: WebWidget.Standalone)

Code.require_file("assets/tests/support/controlled_host.exs")
Code.require_file("assets/tests/support/shared_host.exs")
Code.require_file("assets/tests/support/control.exs")
Code.require_file("assets/tests/support/scoped_control.exs")
{:ok, _} = Supervisor.start_child(WebWidget.Standalone,
  {WebWidget.TestHost.TLSProxy, backend_port: 4024, port: 4023, certfile: cert, keyfile: key})
{:ok, _} = Supervisor.start_child(WebWidget.Standalone,
  {Bandit, plug: {WebWidget.E2EScopedControl, [ca: ca]}, ip: {127, 0, 0, 1}, port: 4021})
Process.sleep(:infinity)
