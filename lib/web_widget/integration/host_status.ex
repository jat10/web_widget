defmodule WebWidget.Integration.HostStatus do
  @moduledoc false
  alias WebWidget.Integration.SignedIdentity

  @settings [:identity_issuer, :identity_audience, :same_site]
  @checks [:runtime, :transport, :delivery, :authentication, :cookie_policy]
  @reasons [
    :runtime_not_registered,
    :runtime_unresponsive,
    :runtime_starting,
    :transport_not_listening,
    :transport_starting,
    :transport_unverifiable,
    :pubsub_unavailable,
    :identity_not_configured,
    :identity_settings_mismatch,
    :cookie_policy_unsupported,
    :cookie_policy_mismatch,
    :secure_cookie_required,
    :https_required,
    :check_timeout,
    :check_failed
  ]

  def project({:ok, response}, desired) do
    if safe_observation?(response) and is_map(desired),
      do: installed(response, desired),
      else: unknown(:check_failed)
  end

  def project({:error, :check_timeout}, _), do: unknown(:check_timeout)
  def project(_, _), do: unknown(:check_failed)

  def unknown(reason) when reason in @reasons do
    %{
      status: :unknown,
      mode: "websocket",
      summary: "Widget readiness unknown",
      reason: reason,
      checks: Map.new(@checks, &{&1, %{status: :unknown, reason: reason}}),
      effective_settings: Map.new(@settings, &{&1, %{value: nil, source: :unresolved}}),
      verification: %{
        scope: :local,
        session_handshake: :not_checked,
        external_https: :not_checked
      }
    }
  end

  def disabled, do: %{unknown(:runtime_not_registered) | status: :disabled, summary: "Disabled"}

  defp installed(response, desired) do
    mismatch =
      Enum.find(@settings, fn key ->
        requested = Map.get(desired, Atom.to_string(key))
        installed = response.effective_settings[key].value
        not is_nil(requested) and not is_nil(installed) and requested != installed
      end)

    response = mismatch(response, mismatch)

    %{
      status:
        %{ready: :ok, starting: :pending, unavailable: :error, unknown: :unknown}[response.status],
      mode: "websocket",
      summary: summary(response),
      reason: response.reason,
      checks: response.checks,
      effective_settings: response.effective_settings,
      verification: response.verification
    }
  end

  defp mismatch(response, nil), do: response

  defp mismatch(response, key) do
    check = if key == :same_site, do: :cookie_policy, else: :authentication
    reason = if key == :same_site, do: :cookie_policy_mismatch, else: :identity_settings_mismatch

    %{
      response
      | status: :unavailable,
        reason: reason,
        checks: Map.put(response.checks, check, %{status: :unavailable, reason: reason})
    }
  end

  defp summary(%{status: :ready, verification: %{session_handshake: :not_checked}}),
    do: "Ready locally; public session handshake and external HTTPS not checked"

  defp summary(%{status: :ready}), do: "Ready locally; external HTTPS not checked"
  defp summary(%{status: :starting}), do: "Widget transport is starting"
  defp summary(%{status: :unavailable}), do: "Widget unavailable"
  defp summary(_), do: "Widget readiness unknown"

  defp safe_observation?(response) do
    exact_keys?(response, [
      :protocol_version,
      :status,
      :reason,
      :checks,
      :effective_settings,
      :verification
    ]) and
      response.protocol_version == 2 and safe_state?(response.status, response.reason) and
      safe_verification?(response.verification) and safe_checks?(response.checks) and
      safe_settings?(response.effective_settings) and resolved_readiness?(response)
  end

  defp safe_checks?(checks) do
    exact_keys?(checks, @checks) and
      Enum.all?(checks, fn {_, check} ->
        exact_keys?(check, [:status, :reason]) and safe_state?(check.status, check.reason)
      end)
  end

  defp safe_settings?(settings) do
    exact_keys?(settings, @settings) and
      Enum.all?(settings, fn {key, setting} ->
        exact_keys?(setting, [:value, :source]) and safe_setting?(key, setting)
      end)
  end

  defp safe_setting?(_, %{value: nil, source: :unresolved}), do: true

  defp safe_setting?(:same_site, %{value: value, source: :connector}),
    do: value in ["None", "Lax", "Strict"]

  defp safe_setting?(key, %{value: value, source: :connector})
       when key in [:identity_issuer, :identity_audience],
       do: SignedIdentity.valid_identifier?(value)

  defp safe_setting?(_, _), do: false

  defp safe_verification?(value) do
    exact_keys?(value, [:scope, :session_handshake, :external_https]) and
      value.scope == :local and value.external_https == :not_checked and
      value.session_handshake in [:verified, :not_checked]
  end

  defp resolved_readiness?(%{status: :ready} = response) do
    Enum.all?(response.checks, fn {_, check} -> check.status == :ready end) and
      Enum.all?(response.effective_settings, fn {_, setting} -> setting.source == :connector end)
  end

  defp resolved_readiness?(_), do: true

  defp safe_state?(:ready, nil), do: true

  defp safe_state?(state, reason),
    do: state in [:starting, :unavailable, :unknown] and reason in @reasons

  defp exact_keys?(map, keys) when is_map(map),
    do: not is_struct(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false
end
