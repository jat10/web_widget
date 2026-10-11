defmodule WebWidget.Embedding.ProxyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias WebWidget.Embedding.Proxy

  defmodule Endpoint do
    def config(:web_widget_proxy) do
      [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://widget.example"]
    end
  end

  defmodule EndpointURL do
    def config(:web_widget_proxy), do: [trusted_proxies: [{10, 0, 0, 1}]]
    def url, do: "https://widget.example"
  end

  setup do
    WebWidget.TestInfrastructure.setup(
      pubsub_server: WebWidget.PubSub,
      proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://widget.example"]
    )
  end

  test "process policy supplies the public origin without reading endpoint configuration" do
    conn = forwarded() |> Map.put(:remote_ip, {10, 0, 0, 1})
    result = Proxy.call(conn, EndpointURL, ["/widget"])
    assert result.scheme == :https
    assert result.host == "widget.example"
    assert result.port == 443
  end

  test "trusted ingress is normalized before session and socket handling" do
    conn = forwarded() |> Map.put(:remote_ip, {10, 0, 0, 1})

    for path <- ["/widget/42/session", "/widget/42/live/websocket"] do
      result = Proxy.call(%{conn | request_path: path}, Endpoint, ["/widget"])
      assert result.scheme == :https
      assert result.host == "widget.example"
      assert result.port == 443
    end
  end

  test "untrusted peers cannot spoof HTTPS and forwarded headers are stripped" do
    result = Proxy.call(forwarded(), Endpoint, ["/widget"])
    assert result.scheme == :http
    assert get_req_header(result, "x-forwarded-proto") == []
    assert get_req_header(result, "x-forwarded-host") == []
    assert get_req_header(result, "x-forwarded-port") == []
  end

  test "trusted peers cannot supply another origin or ambiguous forwarding headers" do
    for {header, value} <- [
          {"x-forwarded-host", "evil.example"},
          {"x-forwarded-proto", "http"},
          {"x-forwarded-port", "443, 80"}
        ] do
      conn = forwarded() |> Map.put(:remote_ip, {10, 0, 0, 1}) |> put_req_header(header, value)
      result = Proxy.call(conn, Endpoint, ["/widget"])
      assert result.status == 400
      assert result.halted
    end
  end

  test "local HTTP does not acquire HTTPS from configuration and BO routes are untouched" do
    result = Proxy.call(conn(:get, "/widget/42"), Endpoint, ["/widget"])
    assert result.scheme == :http
    original = %{forwarded() | request_path: "/bo"}
    assert Proxy.call(original, Endpoint, ["/widget"]) == original
  end

  defp forwarded do
    conn(:get, "/widget/42")
    |> put_req_header("x-forwarded-proto", "https")
    |> put_req_header("x-forwarded-host", "widget.example")
    |> put_req_header("x-forwarded-port", "443")
  end
end
