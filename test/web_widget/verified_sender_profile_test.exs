defmodule WebWidget.VerifiedSenderProfileTest do
  use ExUnit.Case, async: false

  alias WebWidget.Connector.RuntimeConfig
  alias WebWidget.HostAdapter
  alias WebWidget.Integration.{BindingStore, SignedIdentity}
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  @profile %{full_name: "Ada Example", email: "ada@example.com", phone: "+33123456789"}

  setup do
    options = [pubsub_server: WebWidget.PubSub, identity_verifier: :connector_key]
    WebWidget.TestInfrastructure.setup(options)
    reset = BindingStore.reset_cutoff_value()
    assert is_integer(reset)
    await_second(reset + 1)
    start_runtime(options)
  end

  def receive_request(test_pid, payload, context: context) do
    scope = %{channel_config_id: context.options.channel_config_id}
    result = HostAdapter.fetch_profile(context.options.sender_id, scope)
    send(test_pid, {:sink_profile, result, payload, context})
    {:ok, :received}
  end

  test "signed profile is available synchronously at init without entering host payloads", ctx do
    {:ok, proof} =
      SignedIdentity.sign(
        ctx.config.token,
        ctx.config.id,
        %{user_id: "visitor", profile: @profile},
        issuer: "test-issuer",
        audience: "test-audience"
      )

    assert {:ok, session} = Runtime.authenticate(ctx.id, proof, "profile-page")
    assert {:ok, @profile} = fetch(ctx)

    assert {:ok, @profile} =
             HostAdapter.fetch_profile("visitor", %{
               channel_config_id: ctx.config.id,
               token: "ignored"
             })

    assert {:ok, :received} =
             Runtime.dispatch(%{type: "widget.init", request_id: "init"}, session)

    assert_receive {:sink_profile, {:ok, @profile}, payload, context}
    assert Map.keys(payload.constructed) |> Enum.sort() == [:request_id, :type]

    assert Map.keys(context.options) |> Enum.sort() == [
             :channel_config_id,
             :consumer,
             :delivery,
             :sender_id
           ]

    refute inspect({payload, context}) =~ "ada@example.com"
    refute inspect({payload, context}) =~ proof
    {:ok, public} = Runtime.fetch_widget(ctx.id)
    refute inspect(public) =~ "ada@example.com"
    assert {:ok, @profile} = Task.async(fn -> fetch(ctx) end) |> Task.await()

    assert {:error, :unknown_fields} =
             Runtime.dispatch(%{type: "widget.init", profile: @profile}, session)

    assert {:error, :unknown_fields} =
             Runtime.dispatch(
               %{type: "message.create", message: %{id: "m", content: "hi"}, profile: @profile},
               session
             )
  end

  test "user-only tokens and absent profiles preserve authentication", ctx do
    for profile <- [:absent, nil, %{}] do
      assert {:ok, _} = authenticate(ctx, token(ctx, profile))
      assert {:error, :not_found} = fetch(ctx)
    end

    for scope <- [
          %{},
          %{id: ctx.config.id},
          %{channel_config_id: ctx.id},
          %{channel_config_id: 0},
          nil
        ] do
      assert {:error, :invalid_request} = HostAdapter.fetch_profile("visitor", scope)
    end

    assert {:error, :invalid_request} =
             HostAdapter.fetch_profile(" ", %{channel_config_id: ctx.config.id})

    assert {:error, :not_found} =
             HostAdapter.fetch_profile("other", %{channel_config_id: ctx.config.id})
  end

  test "signed invalid profiles and tampered credentials never replace the verified snapshot",
       ctx do
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile))

    for invalid <- [
          %{full_name: false},
          %{email: "invalid"},
          %{phone: "123"},
          %{role: "admin"},
          "name"
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, token(ctx, invalid))
      assert {:ok, @profile} = fetch(ctx)

      assert {:error, :invalid_identity_config} =
               SignedIdentity.sign(
                 ctx.config.token,
                 ctx.config.id,
                 %{user_id: "visitor", profile: invalid},
                 issuer: "test-issuer",
                 audience: "test-audience"
               )
    end

    assert {:error, :unauthorized} = authenticate(ctx, token(ctx, @profile) <> "x")
    assert {:ok, @profile} = fetch(ctx)
  end

  test "refresh replaces and clears profiles, and old page reconnects cannot roll back", ctx do
    issued = System.system_time(:second)
    old = token(ctx, @profile, iat: issued)
    assert {:ok, first} = authenticate(ctx, old)
    await_second(issued + 1)
    updated = %{@profile | full_name: "Updated Name"}
    replacement = token(ctx, updated, iat: issued + 1)
    assert {:ok, renewed} = Runtime.renew(first, replacement)
    assert renewed.profile == updated
    assert {:ok, ^updated} = fetch(ctx)
    assert {:ok, _} = authenticate(ctx, old)
    assert {:ok, ^updated} = fetch(ctx)

    await_second(issued + 2)
    assert {:ok, _} = Runtime.renew(renewed, token(ctx, :absent, iat: issued + 2))
    assert {:error, :not_found} = fetch(ctx)
    assert {:ok, _} = authenticate(ctx, replacement)
    assert {:error, :not_found} = fetch(ctx)
  end

  test "same-second conflicts fail closed until later issuance", ctx do
    issued = System.system_time(:second)
    old = token(ctx, @profile, iat: issued)
    assert {:ok, _} = authenticate(ctx, old)

    assert {:ok, _} =
             authenticate(ctx, token(ctx, %{@profile | email: "new@example.com"}, iat: issued))

    assert {:error, :not_found} = fetch(ctx)
    assert {:ok, _} = authenticate(ctx, old)
    assert {:error, :not_found} = fetch(ctx)
    await_second(issued + 1)
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile, iat: issued + 1))
    assert {:ok, @profile} = fetch(ctx)
  end

  test "failed renewal cannot clear or replace a sender profile", ctx do
    assert {:ok, current} = authenticate(ctx, token(ctx, @profile))
    assert {:error, :unauthorized} = Runtime.renew(current, token(ctx, %{email: "invalid"}))
    assert {:ok, @profile} = fetch(ctx)

    {:ok, foreign} =
      SignedIdentity.sign(
        ctx.config.token,
        ctx.config.id,
        %{user_id: "another-sender", profile: %{full_name: "Other"}},
        issuer: "test-issuer",
        audience: "test-audience"
      )

    assert {:error, :unauthorized} = Runtime.renew(current, foreign)
    assert {:ok, @profile} = fetch(ctx)

    assert {:error, :not_found} =
             HostAdapter.fetch_profile("another-sender", %{channel_config_id: ctx.config.id})

    assert Runtime.authorized?(current)
  end

  test "identical snapshots extend expiry without allowing shorter credentials to roll it back",
       ctx do
    issued = System.system_time(:second)
    short = token(ctx, @profile, iat: issued, exp: issued + 1)
    assert {:ok, _} = authenticate(ctx, short)
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile, iat: issued, exp: issued + 300))
    assert {:ok, _} = authenticate(ctx, short)
    await_second(issued + 1)
    assert {:ok, @profile} = fetch(ctx)
  end

  test "connector and sender scope are isolated even when signing keys match", ctx do
    other = start_runtime(ctx.options)
    assert other.config.token == ctx.config.token
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile))
    assert {:error, :not_found} = fetch(other)
    assert {:error, :unauthorized} = authenticate(other, token(ctx, @profile))
    assert {:ok, _} = authenticate(other, token(other, %{@profile | full_name: "Other"}))
    assert {:ok, %{full_name: "Other"}} = fetch(other)
    assert {:ok, @profile} = fetch(ctx)

    assert {:error, :not_found} =
             HostAdapter.fetch_profile("unknown", %{channel_config_id: ctx.config.id})
  end

  test "expiry removes access and pruning retains a rollback barrier", ctx do
    now = System.system_time(:second)
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile, exp: now + 1))
    assert {:ok, @profile} = fetch(ctx)
    await_second(now + 1)
    assert {:error, :not_found} = fetch(ctx)
    [{pid, _}] = Registry.lookup(WebWidget.RuntimeRegistry, ctx.id)
    send(pid, :prune_profiles)
    state = :sys.get_state(pid)
    assert state.profiles["visitor"].profile == nil
    assert state.profiles["visitor"].retain_until > now
  end

  test "revocation blocks lookup before asynchronous browser cleanup and newer authorization restores it",
       ctx do
    issued = System.system_time(:second)
    proof = token(ctx, @profile, iat: issued)
    assert {:ok, _} = authenticate(ctx, proof)

    assert {:ok, _, true} =
             BindingStore.revoke_user(
               "test-issuer",
               ctx.config.id,
               "visitor",
               Ecto.UUID.generate(),
               issued,
               issued
             )

    assert {:error, :not_found} = fetch(ctx)
    assert {:error, :backend_revoked} = authenticate(ctx, proof)
    await_second(issued + 1)
    assert {:ok, _} = authenticate(ctx, token(ctx, @profile, iat: issued + 1))
    assert {:ok, @profile} = fetch(ctx)
  end

  test "runtime replacement and unavailable infrastructure discard profile authority", ctx do
    proof = token(ctx, @profile)
    assert {:ok, session} = authenticate(ctx, proof)
    stop_supervised!(ctx.spec.id)
    assert {:error, :not_found} = fetch(ctx)
    start_supervised!(ctx.spec)
    assert {:error, :not_found} = fetch(ctx)
    refute Runtime.authorized?(session)
    assert {:ok, _} = authenticate(ctx, proof)
    assert {:ok, @profile} = fetch(ctx)
    WebWidget.TestInfrastructure.replace(ctx.options)
    assert {:error, :not_found} = fetch(ctx)
  end

  defp start_runtime(options) do
    {config, hooks, _} = Host.fixture()
    hooks = %{hooks | sink_mfa: {__MODULE__, :receive_request, [self()]}}
    {:ok, {spec, []}} = RuntimeConfig.prepare(config, hooks, options)
    start_supervised!(spec)
    %{config: config, options: options, spec: spec, id: to_string(config.id)}
  end

  defp fetch(ctx), do: HostAdapter.fetch_profile("visitor", %{channel_config_id: ctx.config.id})
  defp authenticate(ctx, proof), do: Runtime.authenticate(ctx.id, proof, "profile-page")

  defp token(ctx, profile, opts \\ []) do
    now = System.system_time(:second)

    claims = %{
      "widget_id" => ctx.config.id,
      "user_id" => "visitor",
      "iss" => "test-issuer",
      "aud" => "test-audience",
      "iat" => Keyword.get(opts, :iat, now),
      "exp" => Keyword.get(opts, :exp, now + 300),
      "jti" => Ecto.UUID.generate()
    }

    claims = if profile == :absent, do: claims, else: Map.put(claims, "profile", profile)

    ctx.config.token
    |> JOSE.JWK.from_oct()
    |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp await_second(second) do
    delay = max(0, second * 1000 - System.system_time(:millisecond))
    ref = make_ref()
    Process.send_after(self(), {:clock_reached, ref}, delay)
    assert_receive {:clock_reached, ^ref}, delay + 1000
    assert System.system_time(:second) >= second
  end
end
