defmodule WebWidget.VerifiedSenderProfileTest do
  use ExUnit.Case, async: false

  alias WebWidget.Connector.RuntimeConfig
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
    send(test_pid, {:ingress, payload, context})
    {:ok, :received}
  end

  test "init, message and history carry only the trusted profile envelope in Context", ctx do
    {:ok, proof} =
      SignedIdentity.sign(
        ctx.config.token,
        ctx.config.id,
        %{user_id: "visitor", profile: @profile},
        issuer: "test-issuer",
        audience: "test-audience"
      )

    assert {:ok, session} = authenticate(ctx, proof)

    for event <- events() do
      assert {:ok, :received} = Runtime.dispatch(event, session)
      assert_receive {:ingress, payload, context}
      assert context.options.profile_context == envelope(session, @profile)

      assert Enum.sort(Map.keys(context.options)) ==
               [:channel_config_id, :consumer, :delivery, :profile_context, :sender_id]

      refute Map.has_key?(payload.constructed, :profile)
      refute Map.has_key?(payload.constructed, :profile_context)
      refute inspect(payload) =~ "ada@example.com"
      refute inspect(context) =~ proof
      refute inspect(context) =~ ctx.config.token
    end

    {:ok, public} = Runtime.fetch_widget(ctx.id)
    refute inspect(public) =~ "ada@example.com"
    [{pid, _}] = Registry.lookup(WebWidget.RuntimeRegistry, ctx.id)
    state = :sys.get_state(pid)
    refute Map.has_key?(state, :profiles)
    refute inspect(state) =~ "ada@example.com"
    refute function_exported?(WebWidget.HostAdapter, :fetch_profile, 2)
    refute function_exported?(Runtime, :fetch_profile, 2)
  end

  test "user-only tokens and absent profiles deliver nil Context enrichment", ctx do
    for profile <- [:absent, nil, %{}] do
      assert {:ok, session} = authenticate(ctx, token(ctx, profile))
      assert session.profile == nil
      for event <- events(), do: assert_delivery(session, nil, event)
    end
  end

  test "signed invalid profiles, tampered proofs and browser overrides cannot reach the sink",
       ctx do
    assert {:ok, session} = authenticate(ctx, token(ctx, @profile))

    for invalid <- [
          %{full_name: false},
          %{email: "invalid"},
          %{phone: "123"},
          %{role: "admin"},
          "name"
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, token(ctx, invalid))

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
    assert {:error, :unauthorized} = authenticate(ctx, %{user_id: "visitor", profile: @profile})

    for event <- events(), key <- [:profile, :profile_context, :sender_id, :channel_config_id] do
      assert {:error, :unknown_fields} = Runtime.dispatch(Map.put(event, key, @profile), session)
    end

    refute_received {:ingress, _, _}
    assert_delivery(session, @profile)
  end

  test "refresh replaces and clears the profile transported by the renewed Session", ctx do
    assert {:ok, current} = authenticate(ctx, token(ctx, @profile))
    updated = %{@profile | full_name: "Updated Name"}
    assert {:ok, renewed} = Runtime.renew(current, token(ctx, updated))
    assert renewed.profile == updated
    assert renewed.topic == current.topic
    for event <- events(), do: assert_delivery(renewed, updated, event)

    for absent <- [:absent, nil, %{}] do
      assert {:ok, cleared} = Runtime.renew(renewed, token(ctx, absent))
      assert cleared.profile == nil
      for event <- events(), do: assert_delivery(cleared, nil, event)
    end
  end

  test "independent same-second sessions carry their own assertions without a global snapshot",
       ctx do
    issued = System.system_time(:second)
    old_proof = token(ctx, @profile, iat: issued)
    assert {:ok, first} = authenticate(ctx, old_proof)
    other = %{@profile | email: "new@example.com"}

    assert {:ok, second} =
             Runtime.authenticate(ctx.id, token(ctx, other, iat: issued), "other-page")

    assert_delivery(first, @profile)
    assert_delivery(second, other)
    assert {:ok, reconnected} = authenticate(ctx, old_proof)
    assert_delivery(reconnected, @profile)
  end

  test "failed or cross-sender renewal leaves the current Session's transport unchanged", ctx do
    assert {:ok, current} = authenticate(ctx, token(ctx, @profile))
    assert {:error, :unauthorized} = Runtime.renew(current, token(ctx, %{email: "invalid"}))
    foreign = token(ctx, %{full_name: "Other"}, sender: "another-sender")
    assert {:error, :unauthorized} = Runtime.renew(current, foreign)
    refute_received {:ingress, _, _}
    assert Runtime.authorized?(current)
    assert_delivery(current, @profile)
  end

  test "renewal extends only the renewed Session's expiry", ctx do
    issued = System.system_time(:second)
    assert {:ok, short} = authenticate(ctx, token(ctx, @profile, iat: issued, exp: issued + 1))

    assert {:ok, renewed} =
             Runtime.renew(short, token(ctx, @profile, iat: issued, exp: issued + 300))

    await_second(issued + 1)
    assert_blocked(short)
    assert_delivery(renewed, @profile)
  end

  test "connector and sender envelopes remain isolated even when signing keys match", ctx do
    other = start_runtime(ctx.options)
    assert other.config.token == ctx.config.token
    assert {:ok, first} = authenticate(ctx, token(ctx, @profile))
    assert {:error, :unauthorized} = authenticate(other, token(ctx, @profile))
    profile = %{@profile | full_name: "Other"}
    assert {:ok, second} = authenticate(other, token(other, profile, sender: "other-sender"))
    assert_delivery(first, @profile)
    assert_delivery(second, profile)
    assert first.channel_config_id != second.channel_config_id
    assert second.sender_id == "other-sender"

    assert {:error, :unauthorized} =
             Task.async(fn -> Runtime.dispatch(hd(events()), first) end) |> Task.await()

    refute_received {:ingress, _, _}
  end

  test "expiry prevents every protected dispatch before the sink", ctx do
    now = System.system_time(:second)
    assert {:ok, session} = authenticate(ctx, token(ctx, @profile, exp: now + 1))
    assert_delivery(session, @profile)
    await_second(now + 1)
    assert_blocked(session)
  end

  test "revocation blocks transient delivery before browser cleanup and reauthorization restores it",
       ctx do
    issued = System.system_time(:second)
    proof = token(ctx, @profile, iat: issued)
    assert {:ok, session} = authenticate(ctx, proof)

    assert {:ok, _, true} =
             BindingStore.revoke_user(
               "test-issuer",
               ctx.config.id,
               "visitor",
               Ecto.UUID.generate(),
               issued,
               issued
             )

    assert_blocked(session)
    assert {:error, :backend_revoked} = authenticate(ctx, proof)
    await_second(issued + 1)
    assert {:ok, replacement} = authenticate(ctx, token(ctx, @profile, iat: issued + 1))
    assert_delivery(replacement, @profile)
  end

  test "runtime replacement and infrastructure loss invalidate Session transport", ctx do
    proof = token(ctx, @profile)
    assert {:ok, session} = authenticate(ctx, proof)
    stop_supervised!(ctx.spec.id)
    assert_blocked(session)
    start_supervised!(ctx.spec)
    assert_blocked(session)
    assert {:ok, replacement} = authenticate(ctx, proof)
    assert_delivery(replacement, @profile)
    WebWidget.TestInfrastructure.replace(ctx.options)
    assert_blocked(replacement)
  end

  defp assert_delivery(session, profile, event \\ hd(events())) do
    assert {:ok, :received} = Runtime.dispatch(event, session)
    assert_receive {:ingress, _payload, context}
    assert context.options.sender_id == session.sender_id
    assert context.options.channel_config_id == session.channel_config_id
    assert context.options.profile_context == envelope(session, profile)
  end

  defp assert_blocked(session) do
    for event <- events(), do: assert({:error, :unauthorized} = Runtime.dispatch(event, session))
    refute_received {:ingress, _, _}
  end

  defp envelope(_session, nil), do: nil

  defp envelope(session, profile),
    do: %{
      sender_id: session.sender_id,
      channel_config_id: session.channel_config_id,
      profile: profile
    }

  defp events do
    [
      %{type: "widget.init", request_id: "init"},
      %{type: "message.create", request_id: "message", message: %{id: "m", content: "hi"}},
      %{
        type: "conversation.history.request",
        request_id: "history",
        conversation_id: "conversation"
      }
    ]
  end

  defp start_runtime(options) do
    {config, hooks, _} = Host.fixture()
    hooks = %{hooks | sink_mfa: {__MODULE__, :receive_request, [self()]}}
    {:ok, {spec, []}} = RuntimeConfig.prepare(config, hooks, options)
    start_supervised!(spec)
    %{config: config, options: options, spec: spec, id: to_string(config.id)}
  end

  defp authenticate(ctx, proof), do: Runtime.authenticate(ctx.id, proof, "profile-page")

  defp token(ctx, profile, opts \\ []) do
    now = System.system_time(:second)

    claims = %{
      "widget_id" => ctx.config.id,
      "user_id" => Keyword.get(opts, :sender, "visitor"),
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
