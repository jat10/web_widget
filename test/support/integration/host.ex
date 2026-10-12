defmodule WebWidget.TestIntegration.Host do
  @moduledoc false

  alias WebWidget.Connector.RuntimeConfig

  # Recording constructors deliberately avoid implementing another host schema.
  def new(attrs), do: {:ok, %{constructed: attrs}}
  def new(actor, opts), do: {:ok, %{actor: actor, options: Map.new(opts)}}

  def verify(test_pid, proof, scope) do
    send(test_pid, {:verified_scope, scope})

    case proof do
      {:signed, id, sender, expiry} when id == scope.channel_config_id ->
        {:ok, %{sender_id: sender, expires_at: expiry}}

      :raise ->
        raise "private verifier failure"

      _ ->
        {:error, :invalid_proof}
    end
  end

  def receive_request(config, test_pid, %{constructed: attrs}, context: context) do
    send(test_pid, {:ingress, config.id, attrs, context, self()})

    case Map.get(config, :reply) do
      :raise -> raise "private sink failure"
      :throw -> throw(:private_sink_failure)
      :exit -> exit(:private_sink_failure)
      reply -> reply
    end
  end

  def fixture(opts \\ []) do
    id = System.unique_integer([:positive])

    config = %{
      id: id,
      provider: "web_widget",
      token: String.duplicate("private-fixture-key", 3),
      settings: %{
        "same_site" => "Lax",
        "identity_issuer" => "test-issuer",
        "identity_audience" => "test-audience"
      },
      reply: Keyword.get(opts, :reply)
    }

    hooks = %{
      widget_id: id,
      display_name: "Integration #{id}",
      allowed_domains: ["https://parent.example"],
      message: __MODULE__,
      command: __MODULE__,
      delivery: __MODULE__,
      context: __MODULE__,
      response: __MODULE__,
      sink_mfa: {__MODULE__, :receive_request, [config, self()]}
    }

    options = [
      pubsub_server: WebWidget.TestIntegration.PubSub,
      identity_verifier: {__MODULE__, :verify, [self()]}
    ]

    {config, hooks, options}
  end

  def proof(id, sender \\ "verified-parent-user"),
    do: {:signed, id, sender, System.system_time(:second) + 60}

  def runtime_spec(config, hooks) do
    with {:ok, infrastructure} <- WebWidget.Configuration.fetch(),
         {:ok, {spec, []}} <-
           RuntimeConfig.prepare(config, hooks, infrastructure.integration) do
      {module, function, [runtime]} = spec.start
      runtime = Map.put(runtime, :infrastructure_generation, infrastructure.generation)
      {:ok, {%{spec | start: {module, function, [runtime]}}, []}}
    end
  end

  def await_runtime(id, previous \\ nil) do
    await_runtime(id, previous, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_runtime(id, previous, deadline) do
    case WebWidget.Runtime.readiness_snapshot(to_string(id), 100) do
      {:ok, snapshot} when snapshot.runtime_ref != previous ->
        snapshot

      _ ->
        ExUnit.Assertions.assert(
          System.monotonic_time(:millisecond) < deadline,
          "connector did not recover"
        )

        receive do
        after
          10 -> await_runtime(id, previous, deadline)
        end
    end
  end
end
