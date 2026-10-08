defmodule WebWidget.Integration.BindingStoreTest do
  use ExUnit.Case, async: false

  alias WebWidget.Integration.BindingStore

  setup do
    assert :ok = await_store()
    reset = BindingStore.reset_cutoff_value()
    now = max(System.system_time(:second), reset + 1)

    claims = %{
      issuer: "parent",
      audience: "widget",
      widget_id: 100_001,
      user_id: "visitor-#{unique()}",
      jti: unique(),
      iat: now,
      exp: now + 60
    }

    %{claims: claims, now: now}
  end

  test "a first claim binds one verified page and a reconnect may reuse it", ctx do
    assert :ok = BindingStore.claim(ctx.claims, "page-a", ctx.now)
    assert :ok = BindingStore.claim(ctx.claims, "page-a", ctx.now + 6)
    assert :ok = BindingStore.authorized?(ctx.claims, "page-a", ctx.now + 6)
    assert {:error, :replayed} = BindingStore.claim(ctx.claims, "page-b", ctx.now + 6)
    assert {:error, :unauthorized} = BindingStore.authorized?(ctx.claims, "page-b", ctx.now)

    assert {:error, :stale_or_revoked} =
             BindingStore.claim(ctx.claims, "page-a", ctx.claims.exp)
  end

  test "an unseen token must be younger than five seconds", ctx do
    assert {:error, :stale_or_revoked} =
             BindingStore.claim(ctx.claims, "page-a", ctx.now + 5)

    assert :ok = BindingStore.claim(%{ctx.claims | jti: unique()}, "page-a", ctx.now + 4)
  end

  test "concurrent claims have exactly one winning page", ctx do
    results =
      1..12
      |> Task.async_stream(
        fn n -> BindingStore.claim(ctx.claims, "page-#{n}", ctx.now) end,
        max_concurrency: 12,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :replayed})) == 11
  end

  test "revocation is scoped, rejects old credentials and is idempotent", ctx do
    assert :ok = BindingStore.claim(ctx.claims, "page-a", ctx.now)
    request_id = unique()

    assert {:ok, cutoff, true} =
             BindingStore.revoke_user(
               ctx.claims.issuer,
               ctx.claims.widget_id,
               ctx.claims.user_id,
               request_id,
               ctx.now + 1,
               ctx.now + 1
             )

    assert cutoff == ctx.now + 1

    assert {:ok, ^cutoff, false} =
             BindingStore.revoke_user(
               ctx.claims.issuer,
               ctx.claims.widget_id,
               ctx.claims.user_id,
               request_id,
               ctx.now + 1,
               ctx.now + 5
             )

    assert {:error, :stale_or_revoked} =
             BindingStore.claim(ctx.claims, "page-a", ctx.now + 1)

    later = %{ctx.claims | jti: unique(), iat: cutoff + 1, exp: cutoff + 61}
    assert :ok = BindingStore.claim(later, "page-b", cutoff + 1)

    other_user = %{ctx.claims | user_id: "other-#{unique()}", jti: unique()}
    assert :ok = BindingStore.claim(other_user, "page-c", ctx.now + 1)
  end

  defp await_store(remaining \\ 30)
  defp await_store(0), do: BindingStore.available?()

  defp await_store(remaining) do
    case BindingStore.available?() do
      :ok ->
        :ok

      _ ->
        Process.sleep(100)
        await_store(remaining - 1)
    end
  end

  defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
