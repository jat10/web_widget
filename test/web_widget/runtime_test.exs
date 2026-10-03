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

  test "accepts supported themes and stylesheet URLs and rejects invalid values" do
    config = config()
    [widget | _] = config.widgets

    for theme <- ["light", "dark", "auto"] do
      themed = Map.put(widget, :theme, theme)
      start_supervised!({Runtime, %{config | widgets: [themed]}})
      assert Runtime.fetch_widget(widget.widget_id) == {:ok, themed}
      stop_supervised!({Runtime, config.channel_config_id})
    end

    for theme <- [nil, :dark, "system", "DARK", true] do
      assert {:error, :invalid_runtime_config} =
               Runtime.start_link(%{config | widgets: [Map.put(widget, :theme, theme)]})
    end

    for url <- [nil, "/css/theme.css?v=2", "https://cdn.example.com/theme.css"] do
      start_supervised!({Runtime, %{config | widgets: [%{widget | stylesheet_url: url}]}})
      stop_supervised!({Runtime, config.channel_config_id})
    end

    for url <- [
          "",
          "theme.css",
          "//cdn.example.com/theme.css",
          "javascript:alert(1)",
          "data:text/css,body{}",
          "https://",
          "https://user@example.com/theme.css",
          123
        ] do
      assert {:error, :invalid_runtime_config} =
               Runtime.start_link(%{config | widgets: [%{widget | stylesheet_url: url}]})
    end
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

  test "normalizes exact origins and rejects unsafe or non-origin entries" do
    config = config()
    [widget | _] = config.widgets
    normalized = %{widget | allowed_origins: ["https://customer.com", "http://localhost:4019"]}

    start_supervised!(
      {Runtime,
       %{
         config
         | widgets: [
             %{
               widget
               | allowed_origins: [
                   "https://customer.com/",
                   "https://customer.com:443",
                   "http://localhost:4019"
                 ]
             }
           ]
       }}
    )

    assert Runtime.fetch_widget(widget.widget_id) == {:ok, normalized}

    for origins <- [
          "https://customer.com",
          [""],
          ["*"],
          ["https://*.customer.com"],
          ["https:"],
          ["null"],
          ["https://customer.com/path"],
          ["https://customer.com?x=1"],
          ["https://customer.com#fragment"],
          ["https://user@customer.com"],
          ["https://customer.com; frame-src *"],
          ["ftp://customer.com"],
          ["https://customer.com:0"],
          ["https://customer.com:65536"],
          ["https://customer.com", "*"]
        ] do
      assert Runtime.start_link(%{config | widgets: [%{widget | allowed_origins: origins}]}) ==
               {:error, :invalid_runtime_config}
    end
  end

  test "malformed public fields and duplicate IDs fail before starting" do
    config = config()
    [widget | _] = config.widgets

    for widgets <- [
          [widget, widget],
          [Map.put(widget, :multiple_conversations, "true")],
          [%{widget | display_name: %{token: "secret"}}],
          [%{widget | allowed_origins: [%{token: "secret"}]}],
          [%{widget | stylesheet_url: %{token: "secret"}}],
          [%{widget | widget_id: ""}]
        ] do
      assert Runtime.start_link(%{config | widgets: widgets}) == {:error, :invalid_runtime_config}
    end
  end
end
