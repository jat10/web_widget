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

  test "exact ngrok default HTTPS headers omit port without trusting the visitor address" do
    host = "8181-2a01-e34-ecab-1670-cd2d-5a14-961f-c96e.ngrok-free.app"

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://#{host}"]
    )

    for path <- [
          "/channels/widget/7",
          "/channels/widget/7/session",
          "/channels/widget/7/live/websocket",
          "/channels/widget/7/live/longpoll"
        ] do
      conn =
        conn(:get, "http://#{host}#{path}")
        |> put_req_header("x-forwarded-host", host)
        |> put_req_header("x-forwarded-proto", "https")
        |> put_req_header("x-forwarded-for", "185.83.86.167")
        |> Map.put(:remote_ip, {10, 0, 0, 1})

      result = Proxy.call(conn, Endpoint, ["/channels/widget"])
      refute result.halted
      assert {result.scheme, result.host, result.port} == {:https, host, 443}
      assert result.remote_ip == {10, 0, 0, 1}
      assert get_req_header(result, "x-forwarded-port") == []

      untrusted =
        Proxy.call(%{conn | remote_ip: {185, 83, 86, 167}}, Endpoint, ["/channels/widget"])

      assert untrusted.scheme == :http
      assert get_req_header(untrusted, "x-forwarded-proto") == []
      assert get_req_header(untrusted, "x-forwarded-host") == []
    end
  end

  test "absent and single explicit443 are accepted, including explicit443 public origin" do
    for origin <- ["https://widget.example", "https://widget.example:443"] do
      WebWidget.TestInfrastructure.replace(
        pubsub_server: WebWidget.PubSub,
        proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: origin]
      )

      for ports <- [[], ["443"]] do
        result = trusted_with_ports(ports) |> Proxy.call(Endpoint, ["/widget"])
        refute result.halted
        assert {result.scheme, result.host, result.port} == {:https, "widget.example", 443}
      end
    end
  end

  test "default origin rejects blank, conflicting, noncanonical, ambiguous and duplicate ports" do
    for ports <- [
          [""],
          ["80"],
          ["8443"],
          ["0443"],
          ["443 "],
          ["443,443"],
          ["443, 80"],
          ["443", "443"],
          ["443", "80"]
        ] do
      result = trusted_with_ports(ports) |> Proxy.call(Endpoint, ["/widget"])
      assert result.status == 400
      assert result.halted
    end
  end

  test "nondefault origin requires its exact explicit forwarded port" do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://widget.example:8443"]
    )

    result = trusted_with_ports(["8443"]) |> Proxy.call(Endpoint, ["/widget"])
    refute result.halted
    assert {result.scheme, result.host, result.port} == {:https, "widget.example", 8443}

    for ports <- [[], ["443"], ["8443", "8443"], ["8443,8443"]] do
      result = trusted_with_ports(ports) |> Proxy.call(Endpoint, ["/widget"])
      assert result.status == 400
      assert result.halted
    end
  end

  test "missing port does not relax required host and protocol validation" do
    for {header, values} <- [
          {"x-forwarded-host", []},
          {"x-forwarded-host", ["evil.example"]},
          {"x-forwarded-host", ["widget.example,widget.example"]},
          {"x-forwarded-host", ["widget.example", "widget.example"]},
          {"x-forwarded-proto", []},
          {"x-forwarded-proto", ["http"]},
          {"x-forwarded-proto", ["https,http"]},
          {"x-forwarded-proto", ["https", "https"]}
        ] do
      conn = trusted_with_ports([]) |> delete_req_header(header)
      conn = %{conn | req_headers: Enum.map(values, &{header, &1}) ++ conn.req_headers}
      result = Proxy.call(conn, Endpoint, ["/widget"])
      assert result.status == 400
      assert result.halted
    end
  end

  test "trusted directHTTP and XForwardedFor alone never acquire HTTPS" do
    conn =
      conn(:get, "/widget/42")
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "185.83.86.167")

    assert Proxy.call(conn, Endpoint, ["/widget"]) == conn
    assert Proxy.call(conn, Endpoint, ["/widget"]).scheme == :http
  end

  test "pre-normalized scheme does not bypass strict trusted forwarded-header validation" do
    valid = trusted_with_ports([]) |> Map.put(:scheme, :https)
    result = Proxy.call(valid, Endpoint, ["/widget"])
    refute result.halted
    assert {result.scheme, result.host, result.port} == {:https, "widget.example", 443}

    for {header, value} <- [
          {"x-forwarded-proto", "http"},
          {"x-forwarded-host", "evil.example"},
          {"x-forwarded-port", "80"}
        ] do
      result = valid |> put_req_header(header, value) |> Proxy.call(Endpoint, ["/widget"])
      assert result.status == 400
      assert result.halted
    end
  end

  test "untrusted peers cannot spoof HTTPS and forwarded headers are stripped" do
    result =
      forwarded()
      |> put_req_header("x-forwarded-for", "10.0.0.1")
      |> Proxy.call(Endpoint, ["/widget"])

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

  defp trusted_with_ports(ports) do
    conn =
      forwarded() |> Map.put(:remote_ip, {10, 0, 0, 1}) |> delete_req_header("x-forwarded-port")

    %{conn | req_headers: Enum.map(ports, &{"x-forwarded-port", &1}) ++ conn.req_headers}
  end
end
