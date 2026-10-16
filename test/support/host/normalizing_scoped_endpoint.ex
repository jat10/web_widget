defmodule WebWidget.TestHost.NormalizingScopedEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :web_widget
  import WebWidget.Endpoint
  web_widget_socket("/widget", scope: "/channels")

  @impl WebWidget.Endpoint
  def web_widget_normalize(conn) do
    # Test host policy: only loopback ingress, single canonical forwarding values.
    headers = ["x-forwarded-proto", "x-forwarded-host", "x-forwarded-port"]

    cond do
      conn.remote_ip != {127, 0, 0, 1} ->
        Enum.reduce(headers, conn, &Plug.Conn.delete_req_header(&2, &1))

      Enum.any?(headers, fn header ->
        case Plug.Conn.get_req_header(conn, header) do
          [] -> false
          [value] -> value == "" or String.contains?(value, [",", " "])
          _ -> true
        end
      end) ->
        conn |> Plug.Conn.send_resp(400, "invalid_host_forwarding") |> Plug.Conn.halt()

      true ->
        rewrite_on = Keyword.get(config(:force_ssl) || [], :rewrite_on, [])
        conn |> Plug.RewriteOn.call(Plug.RewriteOn.init(rewrite_on))
    end
  end

  plug WebWidget.TestHost.ScopedRouter
end
