defmodule WebWidget.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(%WebWidget.Connector.Private{value: opts}), do: start_link(opts)

  def start_link(opts) do
    with {:ok, config} <- WebWidget.Configuration.normalize(opts) do
      deadline = System.monotonic_time(:millisecond) + 5_000
      with :ok <- previous_children(deadline), do: start(config, deadline)
    end
  end

  # Killing the root does not synchronously drain its named children. The host's
  # ordinary supervisor must see one bounded startup, not repeated name conflicts.
  defp previous_children(deadline) do
    if Process.whereis(__MODULE__) do
      :ok
    else
      Enum.reduce_while(
        [WebWidget.Configuration, WebWidget.RuntimeRegistry, WebWidget.Integration.BindingStore],
        :ok,
        fn name, :ok -> drain_named_child(name, deadline) end
      )
    end
  end

  defp drain_named_child(name, deadline) do
    case {Process.whereis(__MODULE__), Process.whereis(name)} do
      {root, _} when is_pid(root) -> {:halt, {:error, {:already_started, root}}}
      {nil, nil} -> {:cont, :ok}
      {nil, pid} -> drain_result(wait_for_exit(pid, deadline))
    end
  end

  defp drain_result(:ok), do: {:cont, :ok}
  defp drain_result(error), do: {:halt, error}

  defp start(config, deadline) do
    case Supervisor.start_link(__MODULE__, config, name: __MODULE__) do
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, pid}}}} = error ->
        case wait_for_exit(pid, deadline) do
          :ok -> start(config, deadline)
          _ -> error
        end

      result ->
        result
    end
  end

  defp wait_for_exit(pid, deadline) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Process.demonitor(ref, [:flush])
        {:error, :infrastructure_still_stopping}
    end
  end

  @impl true
  def init(config) do
    children = [
      {WebWidget.Configuration, config},
      %{
        id: WebWidget.RuntimeRegistry,
        start: {WebWidget.RuntimeRegistry, :start_link, []},
        type: :supervisor
      },
      {WebWidget.Integration.BindingStore, config.authentication}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
