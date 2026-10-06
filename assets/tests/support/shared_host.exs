Code.require_file("test/support/integration/chat_host.ex")

defmodule WebWidget.E2ESharedHost do
  @moduledoc false
  def key, do: "e2e-only-connector-key-never-installed-in-production-420"

  def start do
    host = WebWidget.TestIntegration.ChatHost
    hooks = %{widget_id: 420, display_name: "Shared protocol assistant",
      allowed_domains: ["http://127.0.0.1:4019"], message: host, command: host,
      response: host, context: host, delivery: host,
      sink_mfa: {host, :receive_request, [self()]}}
    {:ok, {spec, []}} = WebWidget.Integration.RuntimeBuilder.build(
      %{id: 420, provider: "web_widget", token: key()}, hooks,
      pubsub_server: WebWidget.PubSub, identity_verifier: :connector_key,
      identity_issuer: "e2e-parent", identity_audience: "e2e-widget")
    Supervisor.start_child(WebWidget.Supervisor, spec)
  end

  def bootstrap(conversation_id \\ nil, ttl \\ 300) do
    now = System.system_time(:second)
    claims = %{widget_id: 420, user_id: "e2e-visitor", conversation_id: conversation_id,
      prompt_context: "Signed page context", iss: "e2e-parent", aud: "e2e-widget",
      iat: now, exp: now + ttl, jti: Ecto.UUID.generate()}
    {token, 0} = System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
      env: [{"WIDGET_TEST_KEY", key()}, {"WIDGET_TEST_CLAIMS", Jason.encode!(claims)}])
    {:ok, script} = WebWidget.Integration.Installation.script(420, "http://127.0.0.1:4020")
    %{identity_token: token, installation_script: script}
  end
end

{:ok, _} = WebWidget.E2ESharedHost.start()
