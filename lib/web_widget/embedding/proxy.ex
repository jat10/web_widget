defmodule WebWidget.Embedding.Proxy do
  @moduledoc """
  Widget-scoped HTTPS normalization for explicitly trusted reverse proxies.

  Configure the serving endpoint with `web_widget_proxy: [trusted_proxies:
  [ip_tuple, ...]]`. The endpoint's HTTPS URL supplies the public origin;
  `public_origin: "https://host.example"` may explicitly override it. The private backend
  must be reachable only by trusted ingress. Ingress must overwrite forwarding
  headers. Requests are normalized before both HTTP and socket dispatch.
  """
  import Plug.Conn
  alias WebWidget.Embedding.Origins

  @headers ["x-forwarded-proto", "x-forwarded-host", "x-forwarded-port"]

  def policy(endpoint) do
    case endpoint.config(:web_widget_proxy) do
      nil -> {:ok, nil}
      opts -> validate(opts, endpoint)
    end
  end

  def call(conn, endpoint, prefixes) do
    if Enum.any?(prefixes, &scoped?(conn.request_path, &1)) do
      normalize(conn, policy(endpoint))
    else
      conn
    end
  end

  defp validate(opts, endpoint) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:public_origin, :trusted_proxies])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         peers when is_list(peers) and peers != [] <- opts[:trusted_proxies],
         true <- Enum.all?(peers, &valid_ip?/1),
         {:ok, [origin]} <- Origins.normalize([public_origin(opts, endpoint)]),
         %URI{scheme: "https"} = uri <- URI.parse(origin) do
      {:ok, %{peers: peers, origin: origin, uri: uri}}
    else
      _ -> {:error, :transport_unverifiable}
    end
  rescue
    _ -> {:error, :transport_unverifiable}
  end

  defp validate(_, _), do: {:error, :transport_unverifiable}

  defp public_origin(opts, endpoint) do
    case Keyword.fetch(opts, :public_origin) do
      {:ok, origin} -> origin
      :error -> endpoint.url()
    end
  end

  defp normalize(conn, {:ok, nil}), do: conn
  defp normalize(conn, {:error, _}), do: reject(conn)

  defp normalize(conn, {:ok, policy}) do
    forwarded? = Enum.any?(@headers, &(get_req_header(conn, &1) != []))

    cond do
      conn.remote_ip not in policy.peers ->
        Enum.reduce(@headers, conn, &delete_req_header(&2, &1))

      not forwarded? ->
        conn

      get_req_header(conn, "x-forwarded-proto") == ["https"] and
        get_req_header(conn, "x-forwarded-host") == [policy.uri.host] and
          get_req_header(conn, "x-forwarded-port") == [Integer.to_string(policy.uri.port)] ->
        %{conn | scheme: :https, host: policy.uri.host, port: policy.uri.port}

      true ->
        reject(conn)
    end
  end

  defp reject(conn), do: conn |> send_resp(400, "invalid_widget_proxy") |> halt()

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    max = if tuple_size(ip) == 4, do: 255, else: 65_535
    Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 <= max))
  end

  defp valid_ip?(_), do: false

  defp scoped?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")
end
