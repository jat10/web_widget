defmodule WebWidget.ApplicationTest do
  use ExUnit.Case, async: false

  test "configuration changes preserve the running endpoint when its configuration is unchanged" do
    endpoint = Process.whereis(WebWidgetWeb.Endpoint)
    url = WebWidgetWeb.Endpoint.url()

    assert is_pid(endpoint)
    assert :ok = WebWidget.Application.config_change([], [], [])
    assert Process.whereis(WebWidgetWeb.Endpoint) == endpoint
    assert WebWidgetWeb.Endpoint.url() == url
  end
end
