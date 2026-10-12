defmodule WebWidget.Embedding.Proxy do
  @moduledoc """
  Widget-scoped HTTPS normalization for explicitly trusted reverse proxies.

  Start infrastructure with `proxy: [trusted_proxies: [ip_tuple, ...],
  public_origin: "https://host.example"]`. These process options exclusively own trust.
  The private backend
  must be reachable only by trusted ingress. Ingress must overwrite forwarding
  headers. Requests are normalized before both HTTP and socket dispatch.
  """
  import Plug.Conn
  alias WebWidget.Embedding.Origins

  @headers ["x-forwarded-proto", "x-forwarded-host", "x-forwarded-port"]

  def policy(_endpoint) do
    case WebWidget.Configuration.fetch() do
      {:ok, config} -> {:ok, config.proxy}
      _ -> {:error, :transport_unverifiable}
    end
  end

  def call(conn, endpoint, prefixes) do
    if Enum.any?(prefixes, &scoped?(conn.request_path, &1)) do
      normalize(conn, policy(endpoint))
    else
      conn
    end
  end

  @doc false
  def normalize_options(nil), do: {:ok, nil}

  def normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:public_origin, :trusted_proxies])),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         peers when is_list(peers) and peers != [] <- opts[:trusted_proxies],
         true <- Enum.all?(peers, &valid_ip?/1),
         true <- peers == Enum.uniq(peers),
         origin when is_binary(origin) and byte_size(origin) <= 2_048 <- opts[:public_origin],
         {:ok, [origin]} <- Origins.normalize([origin]),
         %URI{scheme: "https"} = uri <- URI.parse(origin) do
      {:ok, %{peers: peers, origin: origin, uri: uri}}
    else
      _ -> {:error, :transport_unverifiable}
    end
  rescue
    _ -> {:error, :transport_unverifiable}
  end

  def normalize_options(_), do: {:error, :transport_unverifiable}

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
          forwarded_port?(get_req_header(conn, "x-forwarded-port"), policy.uri.port) ->
        %{conn | scheme: :https, host: policy.uri.host, port: policy.uri.port}

      true ->
        reject(conn)
    end
  end

  defp forwarded_port?([], 443), do: true
  defp forwarded_port?(values, port), do: values == [Integer.to_string(port)]

  defp reject(conn), do: conn |> send_resp(400, "invalid_widget_proxy") |> halt()

  defp valid_ip?(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    max = if tuple_size(ip) == 4, do: 255, else: 65_535
    Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 <= max))
  end

  defp valid_ip?(_), do: false

  defp scoped?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")
end
