defmodule WebWidget.Integration.ReplayGuard do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def claim(nonce, expiry, owner), do: GenServer.call(__MODULE__, {:claim, nonce, expiry, owner})

  @impl true
  def init(_opts) do
    Process.send_after(self(), :prune, 30_000)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, nonce, expiry, owner}, _from, state) do
    case Map.get(state, nonce) do
      nil -> {:reply, :ok, Map.put(state, nonce, {expiry, owner})}
      {^expiry, ^owner} -> {:reply, :ok, state}
      _ -> {:reply, {:error, :replayed}, state}
    end
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.system_time(:second)
    Process.send_after(self(), :prune, 30_000)
    {:noreply, Map.reject(state, fn {_nonce, {expiry, _owner}} -> expiry <= now end)}
  end
end
