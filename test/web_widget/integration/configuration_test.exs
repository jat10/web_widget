defmodule WebWidget.Integration.ConfigurationTest do
  use ExUnit.Case, async: false

  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.TestIntegration.Host

  test "build/2 reads server configuration and fails closed when it is absent" do
    previous = Application.fetch_env(:web_widget, :integration)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:web_widget, :integration, value)
        :error -> Application.delete_env(:web_widget, :integration)
      end
    end)

    {config, hooks, opts} = Host.fixture()
    Application.delete_env(:web_widget, :integration)
    assert RuntimeBuilder.build(config, hooks) == {:error, :invalid_integration_config}

    Application.put_env(:web_widget, :integration, opts)
    assert RuntimeBuilder.build(config, hooks) == RuntimeBuilder.build(config, hooks, opts)
  end
end
