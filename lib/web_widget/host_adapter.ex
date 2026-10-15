defmodule WebWidget.HostAdapter do
  @moduledoc """
  Host-independent supervision, ingress status and installation boundary.

  Process options passed to `infrastructure_child_specs/1` exclusively own PubSub,
  authentication membership/timings, transport, proxy trust and technical cookie
  policy. Shared infrastructure and connector children have independent lifetimes.
  Hooks contain only the five shared constructors and a fixed config-bound sink MFA.
  Scope and presentation come from the resolved connector configuration, not hooks.
  """

  alias WebWidget.{Configuration, Connector, Runtime}
  alias WebWidget.Integration.{HostStatus, Installation, Readiness, SignedIdentity}

  @hooks [:message, :command, :context, :delivery, :response, :sink_mfa]

  @doc """
  Fetches the latest verified sender profile on the connector's runtime node.

  Only `channel_config_id` is read from the trusted scope map. Returns an atom-keyed
  map with `full_name`, `email`, and `phone` (missing fields are nil), or
  `{:error, :not_found}` when no currently authorized profile exists. Hosts may
  retain their user-ID-only fallback. No credential or browser input is accepted.
  """
  @spec fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, :not_found | :invalid_request}
  def fetch_profile(sender_id, %{channel_config_id: id})
      when is_integer(id) and id > 0 and is_binary(sender_id) do
    if SignedIdentity.valid_identifier?(sender_id),
      do: Runtime.fetch_profile(Integer.to_string(id), sender_id),
      else: {:error, :invalid_request}
  end

  def fetch_profile(_, _), do: {:error, :invalid_request}

  @spec infrastructure_child_specs(keyword()) ::
          {:ok, [Supervisor.child_spec()]} | {:error, term()}
  def infrastructure_child_specs(opts) do
    with {:ok, _} <- Configuration.normalize(opts), do: {:ok, [WebWidget.child_spec(opts)]}
  end

  @spec build_runtime_specs(map(), map()) ::
          {:ok, {Supervisor.child_spec() | nil, [Supervisor.child_spec()]}} | {:error, atom()}
  def build_runtime_specs(%{id: id, settings: settings} = config, hooks)
      when is_integer(id) and id > 0 and is_map(settings) and is_map(hooks) do
    if Enum.sort(Map.keys(hooks)) == Enum.sort(@hooks) do
      presentation = %{
        display_name: Map.get(settings, "display_name", Map.get(config, :name)),
        allowed_domains: Map.get(settings, "allowed_domains", [])
      }

      hooks = hooks |> Map.merge(presentation) |> Map.put(:widget_id, id)
      config = Map.merge(config, presentation)
      opts = [config: config, hooks: hooks]

      with {:ok, _} <- Connector.validate(opts),
           do: {:ok, {Connector.child_spec(opts), []}}
    else
      {:error, :invalid_connector_configuration}
    end
  rescue
    _ -> {:error, :invalid_connector_configuration}
  end

  def build_runtime_specs(_, _), do: {:error, :invalid_connector_configuration}

  @spec ingress_status(map(), keyword()) :: {:ok, map()} | {:error, :invalid_request}
  def ingress_status(config, opts \\ [])

  def ingress_status(%{id: id, provider: provider} = config, opts)
      when is_integer(id) and id > 0 and provider in [:web_widget, "web_widget"] do
    with :ok <- status_options(opts) do
      if Map.get(config, :enabled, true) == false do
        {:ok, HostStatus.disabled()}
      else
        {:ok, HostStatus.project(Readiness.status(id, opts), Map.get(config, :settings, %{}))}
      end
    end
  rescue
    _ -> {:ok, HostStatus.unknown(:check_failed)}
  catch
    _, _ -> {:ok, HostStatus.unknown(:check_failed)}
  end

  def ingress_status(_, _), do: {:error, :invalid_request}

  @spec installation(map() | pos_integer(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_widget_installation}
  def installation(config_or_id, base_url, opts \\ [])
  def installation(%{id: id}, base_url, opts), do: installation(id, base_url, opts)

  def installation(id, base_url, opts) when is_integer(id) and id > 0 and is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:public_url, :token_url, :widget_path, :scope])) and
         Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) do
      with {:ok, install_opts} <- installation_options(opts),
           do: Installation.script(id, base_url, install_opts)
    else
      {:error, :invalid_widget_installation}
    end
  rescue
    _ -> {:error, :invalid_widget_installation}
  end

  def installation(_, _, _), do: {:error, :invalid_widget_installation}

  defp installation_options(opts) do
    case Configuration.fetch() do
      {:ok, config} ->
        defaults =
          Keyword.take(config.integration, [:public_url, :token_url, :widget_path, :scope])

        merged = Keyword.merge(defaults, opts)

        if WebWidget.Mount.new(merged) == {:ok, config.mount},
          do: {:ok, merged},
          else: {:error, :invalid_widget_installation}

      _ ->
        {:ok, opts}
    end
  end

  defp status_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) in [[], [:timeout_ms]] and
         is_integer(Keyword.get(opts, :timeout_ms, 2_000)) and
         Keyword.get(opts, :timeout_ms, 2_000) in 1..2_000,
       do: :ok,
       else: {:error, :invalid_request}
  end
end
