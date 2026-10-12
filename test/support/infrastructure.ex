defmodule WebWidget.TestInfrastructure do
  @moduledoc false

  def setup(opts) do
    previous = options()
    replace(opts)
    ExUnit.Callbacks.on_exit(fn -> replace(previous) end)
    :ok
  end

  def options do
    {:ok, config} = WebWidget.Configuration.fetch()

    config.integration
    |> Keyword.drop([:widget_path])
    |> Keyword.put(:authentication, config.authentication)
    |> Keyword.put(:session, config.session)
    |> Keyword.put(:proxy, proxy_options(config.proxy))
    |> Keyword.put(:response_diagnostics, config.response_diagnostics)
    |> Keyword.put(
      :transport,
      config.transport
      |> Map.delete(:prefix)
      |> Map.to_list()
      |> Keyword.put(:widget_path, config.transport.prefix)
    )
  end

  def replace(opts) do
    opts = normalize(opts)
    {:ok, _} = WebWidget.Configuration.normalize(opts)
    _ = Supervisor.terminate_child(WebWidget.Standalone, {WebWidget.Runtime, :standalone_demo})
    _ = Supervisor.delete_child(WebWidget.Standalone, {WebWidget.Runtime, :standalone_demo})
    _ = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)
    _ = Supervisor.delete_child(WebWidget.Standalone, WebWidget)
    {:ok, _} = Supervisor.start_child(WebWidget.Standalone, {WebWidget, opts})
    _ = :sys.get_state(WebWidget.Integration.BindingStore)

    demo =
      WebWidget.Standalone.demo_config(
        allowed_domains: ["http://www.example.com"],
        pubsub_server: opts[:pubsub_server]
      )

    {:ok, _} =
      Supervisor.start_child(
        WebWidget.Standalone,
        Supervisor.child_spec({WebWidget.Runtime, demo}, restart: :temporary)
      )

    :ok
  end

  defp normalize(opts) do
    transport =
      Keyword.get(
        opts,
        :transport,
        Keyword.get(opts, :readiness, [])
        |> Keyword.merge(Keyword.take(opts, [:widget_path]))
      )

    opts
    |> Keyword.drop([:readiness, :widget_path])
    |> Keyword.put(:transport, transport)
    |> Keyword.put_new(:pubsub_server, WebWidget.PubSub)
    |> Keyword.put_new(:session, partitioned: false)
  end

  defp proxy_options(nil), do: nil
  defp proxy_options(policy), do: [trusted_proxies: policy.peers, public_origin: policy.origin]
end
