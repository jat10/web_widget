defmodule WebWidget.Integration.SignedIdentity do
  @moduledoc """
  Short-lived HS256 JWT parent-backend identity assertions. Never expose the signing key.

  Configure `identity_verifier: :connector_key`, `identity_issuer` and
  `identity_audience` in the integration options. Mint a fresh proof for each
  iframe connection using `sign/4` on the authenticated parent backend.
  The third argument is a map containing `:user_id` and optional
  `:conversation_id` and `:prompt_context` (default nil). No other init fields
  are accepted. Standard JWT claims bind issuer, audience, issue/expiry times
  and a random token ID. Use the raw connector key as the HMAC secret, without
  salt or Base64 decoding. Signed tokens provide integrity, not confidentiality.
  """
  alias WebWidget.Integration.{InitClaims, ReplayGuard}

  @claim_keys ~w(widget_id user_id conversation_id prompt_context iss aud iat exp jti nbf)
  @max_age 300
  @max_proof_bytes 200_000

  def sign(key, widget_id, init, opts) do
    now = System.system_time(:second)
    ttl = Keyword.get(opts, :ttl, @max_age)

    with {:ok, init} <- InitClaims.normalize(init),
         true <-
           valid_key?(key) and is_integer(widget_id) and widget_id > 0 and
             is_integer(ttl) and ttl in 1..@max_age and
             identifier?(opts[:issuer]) and identifier?(opts[:audience]) do
      claims = %{
        "widget_id" => widget_id,
        "user_id" => init.user_id,
        "conversation_id" => init.conversation_id,
        "prompt_context" => init.prompt_context,
        "iss" => opts[:issuer],
        "aud" => opts[:audience],
        "iat" => now,
        "exp" => now + ttl,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      }

      {_metadata, token} =
        key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, claims)
        |> JOSE.JWS.compact()

      {:ok, token}
    else
      _ -> {:error, :invalid_identity_config}
    end
  end

  def verify(key, issuer, audience, proof, scope) when is_binary(proof) do
    now = System.system_time(:second)

    with true <- valid_key?(key) and byte_size(proof) <= @max_proof_bytes,
         {true, payload, %JOSE.JWS{fields: header, b64: :undefined}} <-
           JOSE.JWS.verify_strict(JOSE.JWK.from_oct(key), ["HS256"], proof),
         true <- header == %{"typ" => "JWT"},
         {:ok, claims} <- Jason.decode(payload),
         %{
           "widget_id" => id,
           "user_id" => sender,
           "conversation_id" => conversation,
           "prompt_context" => prompt,
           "iss" => ^issuer,
           "aud" => ^audience,
           "iat" => issued,
           "exp" => expiry,
           "jti" => nonce
         } <- claims,
         true <- Enum.all?(Map.keys(claims), &(&1 in @claim_keys)),
         {:ok, init} <-
           InitClaims.normalize(%{
             user_id: sender,
             conversation_id: conversation,
             prompt_context: prompt
           }),
         true <- is_integer(id) and id > 0 and id == scope.channel_config_id,
         true <- valid_times?(issued, expiry, Map.get(claims, "nbf", issued), now),
         true <- identifier?(nonce) and byte_size(nonce) >= 16,
         :ok <- ReplayGuard.claim({id, nonce}, expiry, self()) do
      {:ok, %{sender_id: sender, expires_at: expiry, init: init}}
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def verify(_, _, _, _, _), do: {:error, :unauthorized}

  defp valid_times?(issued, expiry, not_before, now) do
    is_integer(issued) and is_integer(expiry) and is_integer(not_before) and
      issued <= now and not_before <= now and expiry > now and
      expiry > issued and expiry - issued <= @max_age
  end

  def valid_key?(key) when is_binary(key),
    do:
      byte_size(key) >= 32 and String.valid?(key) and
        length(Enum.uniq(String.graphemes(key))) >= 8

  def valid_key?(_), do: false

  defp identifier?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) == value and
        byte_size(value) in 1..255
end
