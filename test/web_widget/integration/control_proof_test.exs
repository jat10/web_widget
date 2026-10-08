defmodule WebWidget.Integration.ControlProofTest do
  use ExUnit.Case, async: true

  alias WebWidget.Integration.{ControlProof, SignedIdentity}

  setup do
    %{key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}
  end

  test "disconnect proof binds operation, scope and short lifetime", %{key: key} do
    opts = [issuer: "parent", audience: "widget:control"]
    assert {:ok, proof} = ControlProof.sign(key, 42, "visitor", opts)

    assert {:ok, %{jti: nonce, iat: issued}} =
             ControlProof.verify(key, "parent", "widget:control", proof, 42, "visitor")

    assert byte_size(nonce) >= 16
    assert is_integer(issued)

    for {widget, user, audience} <- [
          {43, "visitor", "widget:control"},
          {42, "other", "widget:control"},
          {42, "visitor", "widget"}
        ] do
      assert {:error, :unauthorized} =
               ControlProof.verify(key, "parent", audience, proof, widget, user)
    end

    assert {:error, :invalid_control_config} =
             ControlProof.sign(key, 42, "visitor", Keyword.put(opts, :ttl, 31))

    assert {:ok, browser} =
             SignedIdentity.sign(key, 42, %{user_id: "visitor"},
               issuer: "parent",
               audience: "widget"
             )

    assert {:error, :unauthorized} =
             ControlProof.verify(key, "parent", "widget:control", browser, 42, "visitor")
  end

  test "unknown claims, operation and expired proofs fail closed", %{key: key} do
    {:ok, proof} =
      ControlProof.sign(key, 42, "visitor", issuer: "parent", audience: "widget:control")

    [_, payload, _] = String.split(proof, ".")
    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

    for forged <- [
          Map.put(claims, "op", "renew"),
          Map.put(claims, "topic", "foreign"),
          Map.put(claims, "exp", claims["iat"] - 1),
          Map.delete(claims, "user_id")
        ] do
      {_metadata, token} =
        key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, forged)
        |> JOSE.JWS.compact()

      assert {:error, :unauthorized} =
               ControlProof.verify(key, "parent", "widget:control", token, 42, "visitor")
    end
  end
end
