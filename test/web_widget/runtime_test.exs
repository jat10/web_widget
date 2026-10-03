defmodule WebWidget.RuntimeTest do
  use ExUnit.Case, async: true

  alias WebWidget.Runtime

  defp config do
    id = System.unique_integer([:positive])

    %{
      channel_config_id: id,
      sink_mfa: {__MODULE__, :unused_sink, []},
      widgets: [
        %{
          widget_id: "support-#{id}",
          display_name: "Support Assistant",
          allowed_origins: ["https://customer.com"],
          stylesheet_url: "https://customer.com/widget.css"
        },
        %{
          widget_id: "sales-#{id}",
          display_name: "Sales Assistant",
          allowed_origins: ["https://shop.customer.com"],
          stylesheet_url: nil
        }
      ]
    }
  end

  test "one supervised runtime resolves multiple widgets and excludes internal fields" do
    config = config()
    widgets = Enum.map(config.widgets, &Map.merge(&1, %{token: "secret", agent_id: 123}))
    start_supervised!({Runtime, Map.merge(config, %{widgets: widgets, credentials: "secret"})})

    for widget <- config.widgets do
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
    end

    assert Runtime.fetch_widget("missing") == {:error, :not_found}
  end

  test "stopping removes widgets and restarting applies replacement configuration" do
    config = config()
    [widget | _] = config.widgets
    pid = start_supervised!({Runtime, config})
    ref = Process.monitor(pid)

    stop_supervised!({Runtime, config.channel_config_id})
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert Runtime.fetch_widget(widget.widget_id) == {:error, :not_found}

    updated = %{widget | display_name: "Updated assistant"}
    start_supervised!({Runtime, %{config | widgets: [updated]}})
    assert Runtime.fetch_widget(widget.widget_id) == {:ok, updated}
  end

  test "duplicate widget IDs across channel configs fail instead of replacing an owner" do
    config = config()
    start_supervised!({Runtime, config})
    other = %{config | channel_config_id: config.channel_config_id + 1}

    assert {:error, _reason} = start_supervised({Runtime, other})

    for widget <- config.widgets do
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, widget}
    end
  end

  test "malformed public fields and duplicate IDs fail before starting" do
    config = config()
    [widget | _] = config.widgets

    for widgets <- [
          [widget, widget],
          [%{widget | display_name: %{token: "secret"}}],
          [%{widget | allowed_origins: [%{token: "secret"}]}],
          [%{widget | stylesheet_url: %{token: "secret"}}],
          [%{widget | widget_id: ""}]
        ] do
      assert Runtime.start_link(%{config | widgets: widgets}) == {:error, :invalid_runtime_config}
    end
  end
end
