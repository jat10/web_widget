defmodule WebWidget.Mount do
  @moduledoc false

  def new(opts) do
    with {:ok, scope} <- scope(Keyword.get(opts, :scope, "/")),
         {:ok, widget_path} <- widget_path(opts, scope) do
      {:ok,
       %{
         scope: scope,
         widget_path: widget_path,
         api_path: prefix(scope) <> "/widget-api",
         assets_path: prefix(scope) <> "/web_widget/assets"
       }}
    end
  end

  defp scope("/"), do: {:ok, "/"}

  defp scope(value) when is_binary(value) do
    normalized = String.trim_trailing(value, "/")

    if valid_path?(value) or (valid_path?(normalized) and value == normalized <> "/"),
      do: {:ok, normalized},
      else: {:error, :scope}
  end

  defp scope(_), do: {:error, :scope}

  defp widget_path(opts, scope) do
    derived = prefix(scope) <> "/widget"
    value = Keyword.get(opts, :widget_path, derived)

    if valid_path?(value) and (scope == "/" or value == derived),
      do: {:ok, value},
      else: {:error, :widget_path}
  end

  defp valid_path?(path) when is_binary(path) do
    byte_size(path) <= 1_024 and Regex.match?(~r/\A(?:\/[a-zA-Z0-9][a-zA-Z0-9_-]*)+\z/, path)
  end

  defp valid_path?(_), do: false
  defp prefix("/"), do: ""
  defp prefix(scope), do: scope

  def macro!(path, opts, kind) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Keyword.keys(opts) in [[], [:scope]],
         {:ok, mount} <- new(opts),
         suffix <- if(kind == :api, do: "/widget-api", else: "/widget"),
         derived <- if(kind == :api, do: mount.api_path, else: mount.widget_path),
         true <- valid_path?(path),
         true <- mount.scope == "/" or path in [suffix, derived] do
      actual = if mount.scope == "/", do: path, else: derived
      {actual, mount}
    else
      _ -> raise ArgumentError, "invalid web widget mount scope or conflicting prefix"
    end
  end

  def endpoint_matches?(endpoint, mount) do
    if function_exported?(endpoint, :__web_widget_mounts__, 0) do
      Enum.any?(endpoint.__web_widget_mounts__(), fn installed ->
        installed.scope == mount.scope and
          (mount.scope == "/" or installed.widget_path == mount.widget_path)
      end)
    else
      mount.scope == "/"
    end
  end

  def request_matches?(conn) do
    case {conn.private[:web_widget_mount], WebWidget.Configuration.fetch()} do
      {%{scope: scope} = installed, {:ok, config}} ->
        scope == config.mount.scope and
          (scope == "/" or installed == config.mount)

      _ ->
        false
    end
  end

  def socket_matches?(endpoint, uri) do
    with {:ok, config} <- WebWidget.Configuration.fetch(),
         true <- endpoint_matches?(endpoint, config.mount) do
      config.mount.scope == "/" or
        String.starts_with?(uri.path || "", config.mount.widget_path <> "/")
    else
      _ -> false
    end
  end
end
