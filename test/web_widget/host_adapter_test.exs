defmodule WebWidget.HostAdapterTest do
  use ExUnit.Case, async: false
  alias WebWidget.{Configuration, Connector, HostAdapter, Runtime}
  alias WebWidget.Embedding.{Proxy, Session}
  alias WebWidget.TestIntegration.Host

  @shared [:message, :command, :context, :delivery, :response, :sink_mfa]

  setup do
    WebWidget.TestInfrastructure.setup(pubsub_server: WebWidget.PubSub)
    {config, hooks, _} = Host.fixture()
    config = Map.put(config, :name, "Host connector")
    %{config: config, hooks: Map.take(hooks, @shared)}
  end

  test "infrastructure specs validate process policy and contain no connector children" do
    opts = [
      pubsub_server: WebWidget.PubSub,
      session: [partitioned: false],
      proxy: [trusted_proxies: [{127, 0, 0, 1}], public_origin: "https://widget.example"]
    ]

    assert {:ok, [%{id: WebWidget, type: :supervisor}]} =
             HostAdapter.infrastructure_child_specs(opts)

    for invalid <- [
          [pubsub_server: nil],
          [pubsub_server: WebWidget.PubSub, session: [secure: "true"]],
          [pubsub_server: WebWidget.PubSub, authentication: [replica_nodes: []]],
          [pubsub_server: WebWidget.PubSub, proxy: [trusted_proxies: [{127, 0, 0, 1}]]]
        ] do
      assert {:error, {:invalid_widget_configuration, _, _}} =
               HostAdapter.infrastructure_child_specs(invalid)
    end
  end

  test "runtime specs derive scope and presentation from settings, not generic hooks", ctx do
    config = %{
      ctx.config
      | settings:
          Map.merge(
            ctx.config.settings,
            %{"display_name" => "Saved name", "allowed_domains" => ["https://parent.example"]}
          )
    }

    assert {:ok, {spec, []}} = HostAdapter.build_runtime_specs(config, ctx.hooks)
    assert spec.id == {Connector, config.id}
    refute inspect(spec) =~ config.token
    start_supervised!(spec)
    Host.await_runtime(config.id)
    assert {:ok, widget} = Runtime.fetch_widget(to_string(config.id))
    assert widget.widget_id == to_string(config.id)
    assert widget.display_name == "Saved name"
    assert widget.allowed_domains == ["https://parent.example"]

    for extra <- [
          %{widget_id: config.id + 1},
          %{scope: "/channels"},
          %{display_name: "attacker"},
          %{pubsub_server: OtherPubSub},
          %{identity_verifier: :attacker}
        ] do
      assert {:error, :invalid_connector_configuration} =
               HostAdapter.build_runtime_specs(
                 config,
                 Map.merge(ctx.hooks, extra)
               )
    end

    assert {:error, :invalid_connector_configuration} =
             HostAdapter.build_runtime_specs(
               config,
               Map.delete(ctx.hooks, :sink_mfa)
             )
  end

  test "typed session endpoint selectors and proxy trust are process-owned and immutable" do
    opts = [
      pubsub_server: WebWidget.PubSub,
      session: [
        partitioned: false,
        endpoints: [{WebWidget.TestHost.Endpoint, [partitioned: true]}]
      ],
      proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://widget.example"]
    ]

    WebWidget.TestInfrastructure.replace(opts)
    {:ok, snapshot} = Configuration.fetch()

    assert {:ok, %{partitioned: true}} =
             Session.effective(%{same_site: "Lax"}, WebWidget.TestHost.Endpoint, :https)

    assert {:ok, %{partitioned: false, secure: false}} =
             Session.effective(%{same_site: "Lax"}, WebWidgetWeb.Endpoint, :http)

    assert {:ok, policy} = Proxy.policy(WebWidgetWeb.Endpoint)
    assert policy.peers == [{10, 0, 0, 1}]
    assert policy.origin == "https://widget.example"
    assert {:ok, ^snapshot} = Configuration.fetch()

    for invalid <- [
          [
            session: [
              endpoints: [{WebWidget.TestHost.Endpoint, []}, {WebWidget.TestHost.Endpoint, []}]
            ]
          ],
          [session: [endpoints: [{String, []}]]],
          [session: [endpoints: [{nil, []}]]],
          [session: [endpoints: %{WebWidget.TestHost.Endpoint => []}]],
          [session: [endpoints: [{WebWidget.TestHost.Endpoint, [partitioned: "true"]}]]],
          [session: [endpoints: [{WebWidget.TestHost.Endpoint, [secret: "private"]}]]],
          [proxy: [trusted_proxies: [], public_origin: "https://widget.example"]],
          [
            proxy: [
              trusted_proxies: [{10, 0, 0, 1}, {10, 0, 0, 1}],
              public_origin: "https://widget.example"
            ]
          ],
          [proxy: [trusted_proxies: [{999, 0, 0, 1}], public_origin: "https://widget.example"]],
          [proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "http://widget.example"]]
        ] do
      assert {:error, {:invalid_widget_configuration, _, message}} =
               HostAdapter.infrastructure_child_specs(
                 [pubsub_server: WebWidget.PubSub] ++ invalid
               )

      refute message =~ "private"
      assert {:ok, ^snapshot} = Configuration.fetch()
    end
  end

  test "construction is independent of shared infrastructure availability", ctx do
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    assert {:ok, {spec, []}} = HostAdapter.build_runtime_specs(ctx.config, ctx.hooks)
    pid = start_supervised!(spec)
    assert Process.alive?(pid)
    assert {:error, :not_found} = Runtime.fetch_widget(to_string(ctx.config.id))
    assert {:ok, status} = HostAdapter.ingress_status(ctx.config)
    assert status.status == :error
    assert status.reason == :runtime_not_registered
  end

  test "installation supports [] offline, applies running defaults and rejects unsafe opts",
       ctx do
    assert {:ok, text} = HostAdapter.installation(ctx.config, "https://host.example", [])
    assert text =~ "/widget/#{ctx.config.id}"
    refute text =~ ctx.config.token

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      token_url: "/api/widget-token",
      public_url: "https://public.example",
      transport: [widget_path: "/support/chat"]
    )

    assert {:ok, text} = HostAdapter.installation(ctx.config.id, "https://host.example")
    assert text =~ "https://public.example/support/chat/#{ctx.config.id}"
    assert text =~ "data-token-url=\"/api/widget-token\""
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    assert {:ok, _} = HostAdapter.installation(ctx.config.id, "https://host.example", [])

    for opts <- [
          [unknown: "private"],
          [public_url: "https://user:secret@host.example"],
          [token_url: "//evil.example"],
          [widget_path: "/../host"],
          [token_url: "/one", token_url: "/two"],
          %{}
        ] do
      assert {:error, :invalid_widget_installation} =
               HostAdapter.installation(ctx.config.id, "https://host.example", opts)
    end
  end

  test "ingress observations are closed, redacted, bounded and disabled without probing", ctx do
    assert {:ok, status} = HostAdapter.ingress_status(ctx.config)

    assert Enum.sort(Map.keys(status)) ==
             Enum.sort([
               :status,
               :mode,
               :summary,
               :reason,
               :checks,
               :effective_settings,
               :verification
             ])

    refute inspect(status) =~ ctx.config.token
    assert status.mode == "websocket"

    assert {:ok, %{status: :disabled}} =
             HostAdapter.ingress_status(Map.put(ctx.config, :enabled, false))

    for opts <- [[timeout_ms: 0], [timeout_ms: 2_001], [private: "value"], nil, %{}] do
      assert {:error, :invalid_request} = HostAdapter.ingress_status(ctx.config, opts)
    end

    assert {:error, :invalid_request} =
             HostAdapter.ingress_status(%{id: 0, provider: :web_widget}, [])

    assert {:ok, config} = Configuration.fetch()
    assert config.session[:partitioned] == false
  end
end
