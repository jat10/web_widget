defmodule WebWidget.ConnectorTest do
  use ExUnit.Case, async: false

  alias WebWidget.{Configuration, Connector, Runtime}
  alias WebWidget.Integration.{BindingStore, RuntimeBuilder, SignedIdentity}
  alias WebWidget.TestIntegration.Host

  setup do
    opts = [pubsub_server: WebWidget.PubSub, identity_verifier: {Host, :verify, [self()]}]
    WebWidget.TestInfrastructure.setup(opts)
    bridge = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    %{bridge: bridge, opts: opts}
  end

  test "ordinary child specifications retain inputs and use infrastructure providers", ctx do
    {config, hooks, _} = Host.fixture()
    spec = Connector.child_spec(config: config, hooks: hooks)
    assert spec.type == :supervisor
    assert spec.id == {Connector, config.id}
    refute inspect(spec) =~ config.token
    assert {:ok, connector} = DynamicSupervisor.start_child(ctx.bridge, spec)
    assert is_pid(connector)
    assert {:ok, _} = Runtime.fetch_widget(to_string(config.id))
    snapshot = await_runtime(config.id)
    assert snapshot.pubsub_server == WebWidget.PubSub
    assert {:ok, _} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
    assert_receive {:verified_scope, %{channel_config_id: id}}
    assert id == config.id
    refute function_exported?(RuntimeBuilder, :build, 2)
    refute function_exported?(RuntimeBuilder, :build, 3)
  end

  test "duplicate starts are rejected while running and while infrastructure is absent", ctx do
    {config, hooks, _} = Host.fixture()
    opts = [config: config, hooks: hooks]
    assert {:ok, connector} = DynamicSupervisor.start_child(ctx.bridge, {Connector, opts})
    await_runtime(config.id)
    assert {:error, {:already_started, ^connector}} = Connector.start_link(opts)
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    assert {:error, {:already_started, ^connector}} = Connector.start_link(opts)
    assert DynamicSupervisor.count_children(ctx.bridge).active == 1
  end

  test "valid connectors wait for infrastructure without restarting", ctx do
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    {config, hooks, _} = Host.fixture()

    assert {:ok, connector} =
             DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    assert {:error, :not_found} = Runtime.fetch_widget(to_string(config.id))
    monitor = Process.monitor(connector)
    WebWidget.TestInfrastructure.replace(ctx.opts)
    await_runtime(config.id)
    refute_receive {:DOWN, ^monitor, :process, ^connector, _}
  end

  for component <- [Configuration, WebWidget.RuntimeRegistry, WebWidget.Integration.BindingStore] do
    test "#{component} restart reconstructs runtimes and rejects old sessions", ctx do
      component = unquote(component)
      {config, hooks, _} = Host.fixture()

      {:ok, connector} =
        DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

      before = await_runtime(config.id)
      {:ok, session} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
      assert Runtime.authorized?(session)
      {:ok, runtime_monitor} = Runtime.monitor(session)
      old = Process.whereis(component)
      component_monitor = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^component_monitor, :process, ^old, :killed}
      refute Runtime.authorized?(session)
      assert_receive {:DOWN, ^runtime_monitor, :process, _, _}
      after_recovery = await_runtime(config.id, before.runtime_ref)
      refute after_recovery.infrastructure_generation == before.infrastructure_generation
      refute Runtime.authorized?(session)

      assert Enum.any?(DynamicSupervisor.which_children(ctx.bridge), fn {_, pid, _, _} ->
               pid == connector
             end)
    end
  end

  test "whole infrastructure replacement automatically uses new provider configuration", ctx do
    {config, hooks, _} = Host.fixture()

    {:ok, _} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    before = await_runtime(config.id)
    WebWidget.TestInfrastructure.replace(pubsub_server: WebWidget.PubSub)
    recovered = await_runtime(config.id, before.runtime_ref)
    assert recovered.identity.issuer == config.settings["identity_issuer"]
    assert recovered.identity.audience == config.settings["identity_audience"]
    refute recovered.infrastructure_generation == before.infrastructure_generation
  end

  test "unpaused ordinary host supervisor recovers root kills without replacing connectors",
       ctx do
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)

    for attempt <- 1..20 do
      bridge =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: {:root_host, attempt})

      {:ok, root} = DynamicSupervisor.start_child(bridge, {WebWidget, ctx.opts})
      {:ok, unrelated} = DynamicSupervisor.start_child(bridge, {Agent, fn -> :untouched end})
      {config, hooks, _} = Host.fixture()

      {:ok, connector} =
        DynamicSupervisor.start_child(bridge, {Connector, config: config, hooks: hooks})

      before = await_runtime(config.id)
      {:ok, session} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
      root_monitor = Process.monitor(root)
      Process.exit(root, :kill)
      assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
      recovered = await_runtime(config.id, before.runtime_ref)
      refute recovered.infrastructure_generation == before.infrastructure_generation
      refute Runtime.authorized?(session)
      assert :global.whereis_name({Connector, node(), config.id}) == connector
      assert Process.alive?(bridge)
      assert Agent.get(unrelated, & &1) == :untouched

      assert Enum.any?(DynamicSupervisor.which_children(bridge), fn {_, pid, _, _} ->
               pid == connector
             end)

      stop_supervised!({:root_host, attempt})
    end
  end

  test "replacement and subsequent recovery use updated connector inputs", ctx do
    {config, hooks, _} = Host.fixture()

    {:ok, connector} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    before = await_runtime(config.id)
    {:ok, session} = Runtime.authenticate(to_string(config.id), Host.proof(config.id))
    :ok = DynamicSupervisor.terminate_child(ctx.bridge, connector)

    replacement = %{
      config
      | token: String.duplicate("replacement-private-key", 3),
        settings:
          Map.merge(config.settings, %{"same_site" => "Strict", "identity_issuer" => "new"})
    }

    replacement = Map.put(replacement, :display_name, "Replacement")

    {:ok, _} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: replacement, hooks: hooks})

    installed = await_runtime(config.id, before.runtime_ref)
    assert installed.widget.same_site == "Strict"
    assert installed.widget.display_name == "Replacement"
    refute Runtime.authorized?(session)
    WebWidget.TestInfrastructure.replace(pubsub_server: WebWidget.PubSub)
    recovered = await_runtime(config.id, installed.runtime_ref)
    assert recovered.identity.issuer == "new"
    assert recovered.widget.display_name == "Replacement"
    refute Runtime.authorized?(session)
  end

  test "removal during recovery cancels all work and infrastructure cannot resurrect it", ctx do
    {config, hooks, _} = Host.fixture()

    {:ok, connector} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    await_runtime(config.id)
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    ref = Process.monitor(connector)
    :ok = DynamicSupervisor.terminate_child(ctx.bridge, connector)
    assert_receive {:DOWN, ^ref, :process, ^connector, :shutdown}
    WebWidget.TestInfrastructure.replace(ctx.opts)
    assert DynamicSupervisor.count_children(ctx.bridge).active == 0
    assert {:error, :not_found} = Runtime.fetch_widget(to_string(config.id))
    assert :undefined == :global.whereis_name({Connector, node(), config.id})
  end

  test "runtime failure is contained to its connector", ctx do
    {config, hooks, _} = Host.fixture()
    {other, other_hooks, _} = Host.fixture()

    for {config, hooks} <- [{config, hooks}, {other, other_hooks}] do
      {:ok, _} =
        DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})
    end

    before = await_runtime(config.id)
    unaffected = await_runtime(other.id)
    [{pid, _}] = Registry.lookup(WebWidget.RuntimeRegistry, to_string(config.id))
    Process.exit(pid, :kill)
    await_runtime(config.id, before.runtime_ref)
    assert await_runtime(other.id).runtime_ref == unaffected.runtime_ref
  end

  test "key and identifier replacement rejects old JWTs, including after recovery", ctx do
    WebWidget.TestInfrastructure.replace(pubsub_server: WebWidget.PubSub)
    {config, hooks, _} = Host.fixture()

    {:ok, connector} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    before = await_runtime(config.id)
    cutoff = BindingStore.reset_cutoff_value()
    assert is_integer(cutoff)
    delay = max(0, (cutoff + 1) * 1_000 - System.system_time(:millisecond))

    receive do
    after
      delay -> :ok
    end

    {:ok, old_token} =
      SignedIdentity.sign(config.token, config.id, %{user_id: "visitor"},
        issuer: config.settings["identity_issuer"],
        audience: config.settings["identity_audience"]
      )

    id = to_string(config.id)
    assert {:ok, old_session} = Runtime.authenticate(id, old_token, "original-page")
    :ok = DynamicSupervisor.terminate_child(ctx.bridge, connector)

    replacement = %{
      config
      | token: String.duplicate("rotated-connector-key", 3),
        settings:
          Map.merge(config.settings, %{
            "identity_issuer" => "rotated-issuer",
            "identity_audience" => "rotated-audience"
          })
    }

    {:ok, _} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: replacement, hooks: hooks})

    installed = await_runtime(config.id, before.runtime_ref)
    refute Runtime.authorized?(old_session)
    assert {:error, :unauthorized} = Runtime.authenticate(id, old_token, "original-page")

    {:ok, new_token} =
      SignedIdentity.sign(replacement.token, config.id, %{user_id: "visitor"},
        issuer: "rotated-issuer",
        audience: "rotated-audience"
      )

    assert {:ok, new_session} = Runtime.authenticate(id, new_token, "new-page")
    WebWidget.TestInfrastructure.replace(pubsub_server: WebWidget.PubSub)
    await_runtime(config.id, installed.runtime_ref)
    refute Runtime.authorized?(new_session)
    assert {:error, :unauthorized} = Runtime.authenticate(id, old_token, "original-page")
    assert {:ok, _} = Runtime.authenticate(id, new_token, "new-page")
  end

  test "invalid input and lifecycle diagnostics redact secrets", ctx do
    {config, hooks, _} = Host.fixture()

    assert {:error, :invalid_connector_configuration} =
             Connector.start_link(config: %{config | token: "private-invalid"}, hooks: hooks)

    for opts <- [
          nil,
          [],
          [config: config, hooks: hooks, secret: "private-invalid"],
          [config: config, hooks: Map.delete(hooks, :sink_mfa)]
        ] do
      assert {:error, :invalid_connector_configuration} = Connector.start_link(opts)
    end

    {:ok, connector} =
      DynamicSupervisor.start_child(ctx.bridge, {Connector, config: config, hooks: hooks})

    await_runtime(config.id)

    [{_, _, :supervisor, _}, {_, controller, :worker, _}] =
      Supervisor.which_children(connector) |> Enum.sort_by(fn {_, _, type, _} -> type end)

    refute inspect(:sys.get_status(controller)) =~ config.token
    refute inspect(:sys.get_status(connector)) =~ config.token
    refute inspect(:sys.get_status(ctx.bridge)) =~ config.token
  end

  defp await_runtime(id, previous \\ nil) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_runtime(id, previous, deadline)
  end

  defp await_runtime(id, previous, deadline) do
    case Runtime.readiness_snapshot(to_string(id), 100) do
      {:ok, snapshot} when snapshot.runtime_ref != previous ->
        snapshot

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "connector did not recover"

        receive do
        after
          10 -> await_runtime(id, previous, deadline)
        end
    end
  end
end
