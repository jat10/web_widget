defmodule WebWidget.Integration.Deployment do
  @moduledoc false

  def resolve(transport) do
    with {:ok, endpoint} <- endpoint(transport),
         true <-
           WebWidget.Mount.endpoint_matches?(endpoint, %{
             scope: transport.scope,
             widget_path: transport.prefix
           }),
         {:ok, scheme} <- scheme(endpoint, transport.scheme) do
      {:ok, %{transport | endpoint: endpoint, scheme: scheme}}
    else
      false -> {:error, :transport_unverifiable}
      error -> error
    end
  end

  defp endpoint(%{endpoint: endpoint}) when not is_nil(endpoint), do: {:ok, endpoint}

  defp endpoint(%{prefix: prefix}) do
    candidates =
      Enum.filter(Process.registered(), fn name ->
        function_exported?(name, :__web_widget_prefixes__, 0) and
          prefix in name.__web_widget_prefixes__()
      end)

    case candidates do
      [endpoint] -> {:ok, endpoint}
      _ -> {:error, :transport_unverifiable}
    end
  end

  defp scheme(_, scheme) when scheme in [:http, :https], do: {:ok, scheme}

  defp scheme(endpoint, :auto) do
    listeners = Enum.filter([:http, :https], &listening?(endpoint, &1))

    case listeners do
      [scheme] -> {:ok, scheme}
      [] -> {:error, :transport_not_listening}
      _ -> {:error, :transport_unverifiable}
    end
  end

  defp listening?(endpoint, scheme) do
    match?({:ok, _}, endpoint.server_info(scheme))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
