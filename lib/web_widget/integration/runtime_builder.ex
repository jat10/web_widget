defmodule WebWidget.Integration.RuntimeBuilder do
  @moduledoc """
  Builds a package runtime from host-owned shared-protocol hooks.

  `build/2` reads `config :web_widget, :integration` with `:pubsub_server` and
  `:identity_verifier` (an MFA). `build/3` accepts the same options explicitly.
  The verifier is invoked with its configured arguments followed by proof and
  `%{widget_id: string_id, channel_config_id: integer_id}`. It must verify proof
  and scope and return `{:ok, %{sender_id: external_id, expires_at: unix_seconds}}`.
  Missing configuration fails closed. No endpoint or PubSub server is started.
  """

  alias WebWidget.Integration.Installation
  alias WebWidget.Integration.Protocol
  alias WebWidget.Runtime

  def build(config, hooks),
    do: build(config, hooks, Application.get_env(:web_widget, :integration, []))

  @doc "Returns secret-free installation markup for the configured public widget origin."
  def embed_script(widget_id, base_url),
    do:
      Installation.script(widget_id, base_url, Application.get_env(:web_widget, :integration, []))

  def build(%{id: id, provider: provider}, %{widget_id: id} = hooks, opts)
      when is_integer(id) and id > 0 and provider in [:web_widget, "web_widget"] do
    with {:ok, integration} <- Protocol.new(hooks, opts),
         :ok <- display_name(Map.get(hooks, :display_name)),
         {:ok, config} <-
           Runtime.prepare(%{
             channel_config_id: id,
             integration: integration,
             pubsub_server: integration.pubsub_server,
             widgets: [
               %{
                 widget_id: Integer.to_string(id),
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

  def build(_, _, _), do: {:error, :invalid_integration_config}

  defp display_name(name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" and byte_size(name) <= 200,
      do: :ok,
      else: {:error, :invalid_runtime_config}
  end

  defp display_name(_), do: {:error, :invalid_runtime_config}
end
