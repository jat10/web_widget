defmodule WebWidget.Integration.SignedIdentityTest do
  use ExUnit.Case, async: true
  alias WebWidget.Integration.{BindingStore, RuntimeBuilder, SignedIdentity}
  alias WebWidget.Runtime
  alias WebWidget.TestIntegration.Host

  setup do
    {config, hooks, options} = Host.fixture()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    options =
      Keyword.merge(options,
        identity_verifier: :connector_key,
        identity_issuer: "parent",
        identity_audience: "widget"
      )

    config = Map.put(config, :token, key)
    {:ok, {spec, []}} = RuntimeBuilder.build(config, hooks, options)
    start_supervised!(spec)
    reset = await_reset()
    delay = max(0, (reset + 1) * 1_000 - System.system_time(:millisecond))
    if delay > 0, do: Process.sleep(delay)

    %{
      config: config,
      hooks: hooks,
      options: options,
      spec: spec,
      key: key,
      id: to_string(config.id),
      page_id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end

  test "signed proofs bind sender, widget, issuer, audience and expiry", ctx do
    {:ok, proof} = sign(ctx)
    assert {:ok, session} = authenticate(ctx, proof)
    assert session.sender_id == "visitor"
    assert {:ok, _} = authenticate(ctx, proof)

    for bad <- [nil, "visitor", proof <> "x"] do
      assert {:error, :unauthorized} = authenticate(ctx, bad)
    end

    for opts <- [[issuer: "wrong"], [audience: "wrong"]] do
      {:ok, bad} = sign(ctx, opts)
      assert {:error, :unauthorized} = authenticate(ctx, bad)
    end

    {:ok, wrong_widget} =
      SignedIdentity.sign(ctx.key, ctx.config.id + 1, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget"
      )

    assert {:error, :unauthorized} = authenticate(ctx, wrong_widget)

    expired = jwt(ctx.key, Map.put(claims(ctx), "exp", System.system_time(:second) - 1))

    assert {:error, :unauthorized} = authenticate(ctx, expired)
  end

  test "same-page reconnect survives process replacement but not runtime ownership", ctx do
    {:ok, proof} = sign(ctx)
    assert {:ok, session} = authenticate(ctx, proof)

    assert {:ok, reconnected} = Task.async(fn -> authenticate(ctx, proof) end) |> Task.await()
    refute Runtime.authorized?(reconnected)
    assert {:error, :unauthorized} = authenticate(ctx, proof, "other-page")

    assert {:ok, ref} = Runtime.monitor(session)
    stop_supervised!(ctx.spec.id)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
    start_supervised!(ctx.spec)
    refute Runtime.authorized?(session)

    assert {:ok, _} = authenticate(ctx, proof)
  end

  test "rotation rejects old proofs; keys never appear in public configuration", ctx do
    {:ok, proof} = sign(ctx)
    stop_supervised!(ctx.spec.id)
    config = %{ctx.config | token: Base.url_encode64(:crypto.strong_rand_bytes(32))}
    {:ok, {spec, []}} = RuntimeBuilder.build(config, ctx.hooks, ctx.options)
    start_supervised!(spec)
    assert {:error, :unauthorized} = authenticate(ctx, proof)
    {:ok, public} = Runtime.fetch_widget(ctx.id)
    refute inspect(public) =~ ctx.key

    for key <- [nil, "placeholder", String.duplicate("x", 40)] do
      assert {:error, :invalid_identity_config} =
               RuntimeBuilder.build(%{config | token: key}, ctx.hooks, ctx.options)
    end
  end

  defp sign(ctx, overrides \\ []) do
    SignedIdentity.sign(
      ctx.key,
      ctx.config.id,
      %{user_id: "visitor"},
      Keyword.merge([issuer: "parent", audience: "widget"], overrides)
    )
  end

  test "bootstrap claims are signed, schema checked and protected against tampering", ctx do
    init = %{
      user_id: "visitor",
      conversation_id: "saved",
      prompt_context: String.duplicate("context", 1000)
    }

    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.config.id, init, issuer: "parent", audience: "widget")

    assert {:ok, %{init: ^init}} = authenticate(ctx, proof)
    [_, payload, _] = String.split(proof, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

    for invalid <- [
          Map.put(claims, "settings", %{theme: "dark"}),
          Map.put(claims, "prompt_context", %{}),
          Map.put(claims, "conversation_id", false),
          Map.delete(claims, "prompt_context")
        ] do
      forged_schema = jwt(ctx.key, invalid)
      assert {:error, :unauthorized} = authenticate(ctx, forged_schema)
    end

    for invalid <- [
          "visitor",
          %{user_id: "visitor", settings: %{}},
          %{user_id: "visitor", conversation_id: " "},
          %{user_id: "visitor", prompt_context: String.duplicate("x", 100_001)}
        ] do
      assert {:error, :invalid_identity_config} =
               SignedIdentity.sign(ctx.key, ctx.config.id, invalid,
                 issuer: "parent",
                 audience: "widget"
               )
    end

    [part | rest] = String.split(proof, ".")

    assert {:error, :unauthorized} =
             authenticate(ctx, Enum.join([part <> "x" | rest], "."))
  end

  defp claims(ctx) do
    now = System.system_time(:second)

    %{
      "widget_id" => ctx.config.id,
      "user_id" => "visitor",
      "conversation_id" => nil,
      "prompt_context" => nil,
      "iss" => "parent",
      "aud" => "widget",
      "iat" => now,
      "exp" => now + 300,
      "jti" => Ecto.UUID.generate()
    }
  end

  test "Node signs tokens accepted here and verifies tokens signed here", ctx do
    claims =
      Map.merge(claims(ctx), %{
        "conversation_id" => "chat-123",
        "prompt_context" => "Menu — مرحبا"
      })

    {proof, 0} =
      System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
        env: [{"WIDGET_TEST_KEY", ctx.key}, {"WIDGET_TEST_CLAIMS", Jason.encode!(claims)}]
      )

    assert {:ok, %{init: %{conversation_id: "chat-123", prompt_context: "Menu — مرحبا"}}} =
             authenticate(ctx, proof)

    {:ok, proof} = sign(ctx)

    {payload, 0} =
      System.cmd("node", ["test/support/integration/jwt_interop.cjs"],
        env: [{"WIDGET_TEST_KEY", ctx.key}, {"WIDGET_TEST_TOKEN", proof}]
      )

    assert %{
             "user_id" => "visitor",
             "conversation_id" => nil,
             "prompt_context" => nil,
             "iss" => "parent",
             "aud" => "widget"
           } = Jason.decode!(payload)
  end

  test "rejects algorithm confusion, invalid time claims, wrong key and old Phoenix proofs",
       ctx do
    claims = claims(ctx)

    for header <- [
          %{"alg" => "HS512", "typ" => "JWT"},
          %{"alg" => "HS256", "typ" => "other"},
          %{"alg" => "HS256", "typ" => "JWT", "kid" => "remote-key"}
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, claims, header))
    end

    unsigned =
      Base.url_encode64(Jason.encode!(%{alg: "none", typ: "JWT"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> "."

    assert {:error, :unauthorized} = authenticate(ctx, unsigned)

    assert {:error, :unauthorized} =
             authenticate(
               ctx,
               jwt(Base.url_encode64(:crypto.strong_rand_bytes(32)), claims)
             )

    assert {:error, :unauthorized} =
             authenticate(
               ctx,
               Phoenix.Token.sign(ctx.key, "web-widget-init-v2", claims)
             )

    for invalid <- [
          Map.put(claims, "exp", claims["iat"] + 604_801),
          Map.put(claims, "iat", claims["iat"] + 60),
          Map.put(claims, "nbf", claims["iat"] + 60),
          Map.put(claims, "iat", "now"),
          Map.put(claims, "exp", 1.5),
          Map.put(claims, "jti", "short"),
          Map.delete(claims, "iat"),
          Map.put(claims, "widget_id", to_string(ctx.config.id))
        ] do
      assert {:error, :unauthorized} = authenticate(ctx, jwt(ctx.key, invalid))
    end

    assert {:ok, _} =
             authenticate(ctx, jwt(ctx.key, Map.put(claims, "nbf", claims["iat"])))
  end

  defp jwt(key, claims, header \\ %{"alg" => "HS256", "typ" => "JWT"}) do
    key |> JOSE.JWK.from_oct() |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact() |> elem(1)
  end

  defp authenticate(ctx, proof, page_id \\ nil),
    do: Runtime.authenticate(ctx.id, proof, page_id || ctx.page_id)

  defp await_reset(remaining \\ 50)
  defp await_reset(0), do: flunk("binding store did not become available")

  defp await_reset(remaining) do
    case BindingStore.reset_cutoff_value() do
      reset when is_integer(reset) ->
        reset

      _ ->
        Process.sleep(100)
        await_reset(remaining - 1)
    end
  end
end
