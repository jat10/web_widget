defmodule WebWidget.Integration.Installation do
  @moduledoc "Secret-free installation markup for a root-mounted widget endpoint."

  @doc "Uses the configured public origin, or the host base origin with deployment proxying."
  def script(widget_id, base_url, opts \\ [])

  def script(widget_id, base_url, opts) when is_integer(widget_id) and widget_id > 0 do
    with true <- Keyword.keyword?(opts),
         {:ok, _} <- origin(base_url),
         {:ok, url} <- origin(Keyword.get(opts, :public_url, base_url)) do
      src = Phoenix.HTML.html_escape(url <> "/web_widget/assets/embed.js")

      snippet =
        "<script src=\"#{Phoenix.HTML.safe_to_string(src)}\" data-widget-id=\"#{widget_id}\" defer></script>"

      if byte_size(snippet) <= 32_768,
        do: {:ok, snippet},
        else: {:error, :invalid_widget_installation}
    else
      _ -> {:error, :invalid_widget_installation}
    end
  end

  def script(_, _, _), do: {:error, :invalid_widget_installation}

  defp origin(url) when is_binary(url) and byte_size(url) <= 2_048 do
    with true <- String.valid?(url),
         false <- Regex.match?(~r/[\s\\\x00-\x1f\x7f]/u, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"],
         true <- valid_host?(uri.host),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- uri.path in [nil, "", "/"],
         true <- is_integer(uri.port) and uri.port in 1..65_535 do
      {:ok, URI.to_string(%{uri | path: nil})}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp origin(_), do: {:error, :invalid_origin}

  defp valid_host?(host) when is_binary(host),
    do: Regex.match?(~r/\A(?:[a-zA-Z0-9.-]+|[0-9a-fA-F]*:[0-9a-fA-F:.]+)\z/, host)

  defp valid_host?(_), do: false
end
