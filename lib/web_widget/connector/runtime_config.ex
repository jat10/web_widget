defmodule WebWidget.Connector.RuntimeConfig do
  @moduledoc false

  alias WebWidget.Embedding.Session
  alias WebWidget.Integration.Protocol
  alias WebWidget.Integration.SignedIdentity
  alias WebWidget.Runtime

  def prepare(%{id: id, provider: provider} = host_config, %{widget_id: id} = hooks, opts)
      when is_integer(id) and id > 0 and provider in [:web_widget, "web_widget"] do
    providers =
      if is_list(opts) and Keyword.keyword?(opts),
        do: Keyword.take(opts, [:pubsub_server, :identity_verifier]),
        else: []

    with {:ok, opts} <- verification_options(host_config, opts),
         {:ok, same_site} <-
           Session.validate_settings(Map.get(host_config, :settings)),
         {:ok, integration} <- Protocol.new(hooks, opts),
         :ok <- display_name(Map.get(hooks, :display_name)),
         {:ok, config} <-
           Runtime.prepare(%{
             channel_config_id: id,
             infrastructure_providers: providers,
             integration: integration,
             pubsub_server: integration.pubsub_server,
             widgets: [
               %{
                 widget_id: Integer.to_string(id),
                 same_site: same_site,
                 display_name: Map.get(hooks, :display_name),
                 allowed_domains: Map.get(hooks, :allowed_domains, []),
                 stylesheet_url: nil,
                 multiple_conversations: false
               }
             ]
           }) do
      {:ok, {Runtime.child_spec(config), []}}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_integration_config}

  defp verification_options(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts) and opts[:identity_verifier] == :connector_key do
      key = Map.get(config, :token)
      settings = Map.get(config, :settings)
      issuer = if is_map(settings), do: Map.get(settings, "identity_issuer")
      audience = if is_map(settings), do: Map.get(settings, "identity_audience")

      if SignedIdentity.valid_key?(key) and
           SignedIdentity.valid_identifier?(issuer) and SignedIdentity.valid_identifier?(audience) do
        {:ok,
         opts
         |> Keyword.put(:identity_verifier, {SignedIdentity, :verify, [key, issuer, audience]})
         |> Keyword.put(:identity_source, :connector)
         |> Keyword.put(:control_key, key)
         |> Keyword.put(:control_issuer, issuer)
         |> Keyword.put(:control_audience, audience <> ":control")}
      else
        {:error, :invalid_identity_config}
      end
    else
      {:ok, Keyword.delete(opts, :identity_source)}
    end
  end

  defp verification_options(_, _), do: {:error, :invalid_integration_config}

  defp display_name(name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" and byte_size(name) <= 200,
      do: :ok,
      else: {:error, :invalid_runtime_config}
  end

  defp display_name(_), do: {:error, :invalid_runtime_config}
end
