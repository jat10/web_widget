defmodule WebWidget.Connector do
  @moduledoc """
  Host-supervised connector, independent of widget infrastructure restarts.

      {WebWidget.Connector, config: connector_config, hooks: host_hooks}

  Configuration uses the resolved host connector shape: positive `id`,
  `provider: :web_widget`, private `token`, and string-keyed `settings` containing
  `identity_issuer`, `identity_audience` and `same_site`. Presentation values
  `display_name` and `allowed_domains` may be on config or the trusted hooks.
  Hooks supply the matching `widget_id`, shared constructors and `sink_mfa`.
  Replace this entire child to change configuration; terminate it to remove it.
  """
  use Supervisor

  alias WebWidget.Connector.{Controller, Private, RuntimeConfig}

  def child_spec(opts) do
    id = connector_id(opts)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [%Private{value: opts}]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  def start_link(%Private{value: opts}), do: start_link(opts)

  def start_link(opts) do
    with {:ok, inputs} <- validate(opts) do
      Supervisor.start_link(__MODULE__, %Private{value: inputs}, name: name(inputs.config.id))
    end
  end

  @impl true
  def init(%Private{value: inputs} = private) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: runtime_supervisor(inputs.config.id)},
      {Controller, private}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc false
  def name(id), do: {:global, {__MODULE__, node(), id}}

  @doc false
  def runtime_supervisor(id), do: {:global, {__MODULE__.RuntimeSupervisor, node(), id}}

  defp validate(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.sort(Keyword.keys(opts)) == [:config, :hooks],
         %{id: id} = config <- opts[:config],
         true <- is_integer(id) and id > 0,
         hooks when is_map(hooks) <- opts[:hooks],
         hooks <- Map.merge(hooks, Map.take(config, [:display_name, :allowed_domains])),
         {:ok, _} <-
           RuntimeConfig.prepare(config, hooks,
             pubsub_server: WebWidget.ValidationPubSub,
             identity_verifier: :connector_key
           ) do
      {:ok, %{config: config, hooks: hooks}}
    else
      _ -> {:error, :invalid_connector_configuration}
    end
  rescue
    _ -> {:error, :invalid_connector_configuration}
  end

  defp validate(_), do: {:error, :invalid_connector_configuration}

  defp connector_id(opts) when is_list(opts) do
    case Keyword.keyword?(opts) && Keyword.get(opts, :config) do
      %{id: id} when is_integer(id) and id > 0 -> id
      _ -> nil
    end
  end

  defp connector_id(_), do: nil
end
