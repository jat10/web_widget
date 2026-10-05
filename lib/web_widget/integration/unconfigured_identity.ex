defmodule WebWidget.Integration.UnconfiguredIdentity do
  @moduledoc """
  Rejects authentication while an installation is verifying runtime wiring.

  Configure this MFA to start channel runtimes before a production identity
  verifier is installed. It never grants a session, including for same-origin
  callers. Replace the configured MFA with a real verifier before chat use.
  """

  @spec verify(term(), map()) :: {:error, :identity_verifier_not_configured}
  def verify(_proof, _scope), do: {:error, :identity_verifier_not_configured}
end
