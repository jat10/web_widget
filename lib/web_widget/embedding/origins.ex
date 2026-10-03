defmodule WebWidget.Embedding.Origins do
  @moduledoc false

  def normalize(nil), do: {:ok, []}

  def normalize(origins) when is_list(origins) do
    Enum.reduce_while(origins, {:ok, []}, fn origin, {:ok, acc} ->
      case normalize_origin(origin) do
        {:ok, origin} -> {:cont, {:ok, Enum.uniq(acc ++ [origin])}}
        :error -> {:halt, :error}
      end
    end)
  end

  def normalize(_), do: :error

  defp normalize_origin(origin) when is_binary(origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- uri.scheme in ["http", "https"],
         true <- valid_host?(uri.host),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, "", "/"] do
      {:ok, URI.to_string(%{uri | host: String.downcase(uri.host), path: nil})}
    else
      _ -> :error
    end
  end

  defp normalize_origin(_), do: :error

  defp valid_host?(host) when is_binary(host) and host != "" do
    Regex.match?(~r/\A[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*\z/, host) or
      match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(host)))
  end

  defp valid_host?(_), do: false
end
