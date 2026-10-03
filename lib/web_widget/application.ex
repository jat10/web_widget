defmodule WebWidget.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [{Registry, keys: :unique, name: WebWidget.RuntimeRegistry}] ++ web_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: WebWidget.Supervisor)
  end

  # Hosts may use the supervised runtime without starting the standalone Phoenix
  # server and database. Runtime children remain owned by the host supervisor.
  defp web_children do
    if Application.get_env(:web_widget, :start_web_server, false),
      do: standalone_children(),
      else: []
  end

  defp standalone_children do
    [
      {WebWidget.Runtime,
       %{
         channel_config_id: :standalone_demo,
         sink_mfa: {__MODULE__, :unused, []},
         widgets: [
           %{
             widget_id: "demo",
             display_name: "Website assistant",
             allowed_origins: Application.get_env(:web_widget, :demo_allowed_origins, [])
           }
         ]
       }},
      WebWidgetWeb.Telemetry,
      WebWidget.Repo,
      {DNSCluster, query: Application.get_env(:web_widget, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WebWidget.PubSub},
      # Start a worker by calling: WebWidget.Worker.start_link(arg)
      # {WebWidget.Worker, arg},
      # Start to serve requests, typically the last entry
      WebWidgetWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    if Process.whereis(WebWidgetWeb.Endpoint) do
      WebWidgetWeb.Endpoint.config_change(changed, removed)
    end

    :ok
  end
end
