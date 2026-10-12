defmodule WebWidget.Integration.HostStatusTest do
  use ExUnit.Case, async: true
  alias WebWidget.Integration.HostStatus

  defp ready do
    %{
      protocol_version: 2,
      status: :ready,
      reason: nil,
      checks:
        Map.new(
          [:runtime, :transport, :delivery, :authentication, :cookie_policy],
          &{&1, %{status: :ready, reason: nil}}
        ),
      effective_settings: %{
        identity_issuer: %{value: "host", source: :connector},
        identity_audience: %{value: "widget", source: :connector},
        same_site: %{value: "Lax", source: :connector}
      },
      verification: %{scope: :local, session_handshake: :verified, external_https: :not_checked}
    }
  end

  test "desired inputs are compared with installed evidence without inventing green checks" do
    observed = ready()
    assert %{status: :ok} = HostStatus.project({:ok, observed}, %{})

    for key <- ["identity_issuer", "identity_audience", "same_site"] do
      result = HostStatus.project({:ok, observed}, %{key => "Changed"})
      assert result.status == :error
      assert result.effective_settings == observed.effective_settings

      assert result.reason ==
               if(key == "same_site",
                 do: :cookie_policy_mismatch,
                 else: :identity_settings_mismatch
               )
    end

    guarded = put_in(observed.verification.session_handshake, :not_checked)

    assert HostStatus.project({:ok, guarded}, %{}).summary ==
             "Feed ready locally; session handshake and external HTTPS not checked"
  end

  test "malformed or private observations never escape the closed boundary" do
    observed = ready()

    for invalid <- [
          Map.put(observed, :secret, "PRIVATE"),
          %{observed | reason: "PRIVATE"},
          %{observed | protocol_version: 99},
          put_in(observed.checks.runtime, %{status: :unknown, reason: :check_failed}),
          put_in(observed.effective_settings.same_site.source, :endpoint),
          put_in(observed.effective_settings.identity_issuer.value, " PRIVATE "),
          put_in(observed.verification.external_https, :verified),
          nil
        ] do
      assert %{status: :unknown, reason: :check_failed} = HostStatus.project({:ok, invalid}, %{})
      refute inspect(HostStatus.project({:ok, invalid}, %{})) =~ "PRIVATE"
    end

    assert %{status: :unknown, reason: :check_timeout} =
             HostStatus.project({:error, :check_timeout}, %{})

    assert %{status: :unknown, reason: :check_failed} =
             HostStatus.project({:error, %{secret: "PRIVATE"}}, %{})
  end
end
