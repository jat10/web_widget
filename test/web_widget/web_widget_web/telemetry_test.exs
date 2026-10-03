defmodule WebWidgetWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "dashboard metrics expose request, database and VM measurements with their units" do
    metrics = Map.new(WebWidgetWeb.Telemetry.metrics(), &{&1.name, &1})

    request = Map.fetch!(metrics, [:phoenix, :router_dispatch, :stop, :duration])
    assert request.event_name == [:phoenix, :router_dispatch, :stop]
    assert request.tags == [:route]
    assert request.unit == :millisecond

    query = Map.fetch!(metrics, [:web_widget, :repo, :query, :total_time])
    assert query.event_name == [:web_widget, :repo, :query]
    assert query.unit == :millisecond

    memory = Map.fetch!(metrics, [:vm, :memory, :total])
    assert memory.unit == :kilobyte
    assert Map.has_key?(metrics, [:vm, :total_run_queue_lengths, :cpu])
    assert Map.has_key?(metrics, [:vm, :total_run_queue_lengths, :io])
  end
end
