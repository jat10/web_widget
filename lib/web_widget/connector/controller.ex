defmodule WebWidget.Connector.Controller do
  @moduledoc false
  use GenServer

  alias WebWidget.{Configuration, Connector, Runtime}
  alias WebWidget.Connector.{Private, RuntimeConfig}
  alias WebWidget.Integration.BindingStore

  def start_link(private), do: GenServer.start_link(__MODULE__, private)

  @impl true
  def init(%Private{value: inputs}) do
    state = %{
      inputs: inputs,
      runtime: nil,
      runtime_monitor: nil,
      owner_monitor: nil,
      timer: nil,
      attempt: 0
    }

    {:ok, recover(state)}
  end

  @impl true
  def handle_info({:recover, token}, %{timer: {_, token}} = state),
    do: {:noreply, recover(%{state | timer: nil})}

  def handle_info({:DOWN, ref, :process, _, _}, state)
      when ref == state.owner_monitor or ref == state.runtime_monitor do
    stop_runtime(state)
    demonitor(state.owner_monitor)
    demonitor(state.runtime_monitor)

    {:noreply, schedule(%{state | runtime: nil, runtime_monitor: nil, owner_monitor: nil})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status), do: Map.put(status, :state, :private_connector_lifecycle)

  defp recover(state) do
    case construct(state.inputs) do
      {:ok, pid, owner} ->
        %{
          state
          | runtime: pid,
            runtime_monitor: Process.monitor(pid),
            owner_monitor: Process.monitor(owner),
            attempt: 0
        }

      _ ->
        schedule(state)
    end
  end

  # Shutdown of the containing supervisor owns the runtime supervisor and timers;
  # no process outside this subtree retains inputs or can recreate the connector.
  defp construct(inputs) do
    with {:ok, infrastructure} <- Configuration.fetch(),
         true <- is_pid(Process.whereis(WebWidget.RuntimeRegistry)),
         :ok <- BindingStore.available?(),
         {:ok, {spec, []}} <-
           RuntimeConfig.prepare(inputs.config, inputs.hooks, infrastructure.integration) do
      {_, _, [config]} = spec.start
      config = Map.put(config, :infrastructure_generation, infrastructure.generation)

      spec = %{
        spec
        | start: {Runtime, :start_link, [%Private{value: config}]},
          restart: :temporary
      }

      install(inputs.config.id, spec, infrastructure)
    else
      _ -> {:error, :infrastructure_unavailable}
    end
  rescue
    _ -> {:error, :infrastructure_unavailable}
  catch
    :exit, _ -> {:error, :infrastructure_unavailable}
  end

  defp install(id, spec, infrastructure) do
    case DynamicSupervisor.start_child(Connector.runtime_supervisor(id), spec) do
      {:ok, pid} ->
        if Configuration.live?(infrastructure) and BindingStore.available?() == :ok do
          {:ok, pid, infrastructure.owner}
        else
          DynamicSupervisor.terminate_child(Connector.runtime_supervisor(id), pid)
          {:error, :infrastructure_changed}
        end

      _ ->
        {:error, :runtime_unavailable}
    end
  end

  defp schedule(%{timer: timer} = state) when not is_nil(timer), do: state

  defp schedule(state) do
    delay = min(50 * Integer.pow(2, min(state.attempt, 5)), 1_000) + :rand.uniform(50)
    token = make_ref()
    timer = Process.send_after(self(), {:recover, token}, delay)
    %{state | timer: {timer, token}, attempt: state.attempt + 1}
  end

  defp stop_runtime(%{runtime: nil}), do: :ok

  defp stop_runtime(state) do
    DynamicSupervisor.terminate_child(
      Connector.runtime_supervisor(state.inputs.config.id),
      state.runtime
    )
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])
end
