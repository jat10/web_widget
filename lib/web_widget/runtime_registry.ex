defmodule WebWidget.RuntimeRegistry do
  @moduledoc false

  def start_link do
    start(System.monotonic_time(:millisecond) + 5_000)
  end

  # A killed Registry supervisor can return before its linked partitions release
  # their names. Wait on the conflicting process, rather than consuming the
  # infrastructure supervisor's restart budget on the same dying partition.
  defp start(deadline) do
    case Registry.start_link(keys: :unique, name: __MODULE__) do
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_started, pid}}}} = error ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> start(deadline)
          after
            remaining ->
              Process.demonitor(ref, [:flush])
              error
          end
        else
          error
        end

      result ->
        result
    end
  end
end
