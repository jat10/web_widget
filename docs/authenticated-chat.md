# Authenticated ZAQ chat smoke

## Response diagnostics

After compiling/restarting ZAQ with the current path dependency, enable diagnostic
logs in its IEx session:

```elixir
Application.put_env(:web_widget, :response_diagnostics, true)
:logger.update_formatter_config(:default, :truncate, :infinity)
```

Send a new message or reload a saved conversation. Look for `[web_widget.response]`
in ZAQ's server logs. Entries contain the complete received response and payload,
including nested fields, together with whether a live event was applied or ignored.
Inspection has no collection/string limits; the Logger setting above also removes
its message-size truncation. Full responses may include private content, so use
this only while debugging. No authentication/session object is added to the log.
Use `:summary` instead of `true` for field-presence/count diagnostics without
payload values. Disable with `false`, and restore your previous Logger truncation
setting when finished (Elixir's default is `8192`).

The current ZAQ widget stream reduces tool status to generic `activity/running`
steps; its final widget payload and canonical history omit tool traces. Thus BO
can show a persisted tool call while the widget receives no explicit tool event
or result. The package's shared response adapter currently maps only generic
activity steps. Displaying real tool calls requires an agreed public tool-event
contract from ZAQ and corresponding adapter support; generic activity must not
be guessed to be a tool call.

## Setup

Keep the existing builder and router/static mount. Opt in to connector-key
verification in ZAQ configuration; no ZAQ source implementation is needed:

```elixir
config :web_widget, :integration,
  pubsub_server: Zaq.PubSub,
  identity_verifier: :connector_key,
  identity_issuer: "test-widget",
  identity_audience: "zaq-web-widget"
```

Keep Phoenix parameter filtering for `token` and `secret` enabled (ZAQ already
configures these) so proof values do not enter request logs.

Run `mix deps.get` in ZAQ to fetch the new JOSE dependency, then restart ZAQ
after changing configuration and enable the connector in BO. The
builder consumes its resolved `config.token` privately. Missing/placeholder keys
fail configuration validation. Keep the generated key in the embedding website's
backend secret store. Never include it in HTML, the installation script or `init`.

On that authenticated backend, derive the sender from the logged-in session and
mint a proof with the same issuer/audience and the numeric BO widget ID:

```elixir
{:ok, identity_token} = WebWidget.Integration.SignedIdentity.sign(
  connector_key, 12,
  %{
    user_id: authenticated_external_user_id,
    conversation_id: requested_conversation_id, # nil for a new conversation
    prompt_context: "Current page: /menu" # or nil
  },
  issuer: "test-widget", audience: "zaq-web-widget", ttl: 300
)
```

Tokens now use standard **JWT with HS256 (HMAC-SHA256)**, verified with
[JOSE's strict algorithm allowlist](https://hexdocs.pm/jose/JOSE.JWS.html#verify_strict/3).
There is no salt or Phoenix-specific encoding. Use the exact authentication key
copied from ZAQ BO as UTF-8 secret bytes; **do not Base64-decode it**. Any language
can issue this JWT using its JWT library. Existing Phoenix.Token proofs are rejected.

The required JWT header is `{"alg":"HS256","typ":"JWT"}`. Only those header
fields are supported. Required payload fields are:

| Claim | Value |
| --- | --- |
| `widget_id` | Numeric positive connector ID, e.g. `12` (not `"12"`). |
| `user_id` | Nonblank authenticated external user ID, at most 255 bytes. |
| `conversation_id` | Existing conversation ID or JSON `null`. |
| `prompt_context` | String of at most 100,000 UTF-8 bytes or JSON `null`. |
| `iss` | Exact configured `identity_issuer`. |
| `aud` | Exact configured `identity_audience` string. |
| `iat` | Issued-at time, integer Unix seconds. |
| `exp` | Expiration time, integer Unix seconds; after `iat` and at most 300 seconds later. |
| `jti` | Fresh random token ID, e.g. UUID v4; 16–255 characters. |

Optional `nbf` must be integer Unix seconds and no later than the current time.
Future `iat`, expired tokens, unknown claims (including settings), and other
algorithms are rejected. Clocks must be synchronized; no clock-skew allowance is
applied. Signing protects integrity, not confidentiality: do not put secrets in
prompt context.

### Website backend example: Node.js

Store the BO key in your **backend** environment as `ZAQ_WIDGET_SECRET`.
Install [jose](https://github.com/panva/jose) in that backend with `npm install jose`.
The existing authentication/CSRF middleware and input validation are supplied by
your website; do not expose a signing endpoint that accepts arbitrary user IDs.

```javascript
import { SignJWT } from "jose";
import { randomUUID } from "node:crypto";

const secret = process.env.ZAQ_WIDGET_SECRET;
if (!secret) throw new Error("Missing ZAQ_WIDGET_SECRET");
const key = new TextEncoder().encode(secret);

// Call after authenticating the visitor and validating resume/context inputs.
async function issueWidgetToken(authenticatedUserId, conversationId, promptContext) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    widget_id: 12,
    user_id: authenticatedUserId,
    conversation_id: conversationId ?? null,
    prompt_context: promptContext ?? null
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer("test-widget")
    .setAudience("zaq-web-widget")
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .setJti(randomUUID())
    .sign(key);
}

// Inside POST /api/widget-identity, after your session/CSRF checks:
// const token = await issueWidgetToken(req.user.id, validatedConversationId, validatedContext);
// res.set("Cache-Control", "no-store").json({ identity_token: token });
```

Python, PHP, Go and other backends should sign the same JSON claims with HS256
using the same raw secret. No Elixir service or signer is required. The Elixir
helper above is optional convenience for Phoenix backends.

### Website frontend

The frontend calls its own backend endpoint using its existing login session.
That endpoint returns JSON containing the signed JWT, not the connector key.
The frontend passes the JWT to the iframe via `init`; the iframe forwards it
through LiveView to the server-side widget verifier inside ZAQ.

After the unchanged BO installation script has loaded, initialize in the browser:

```javascript
const frame = document.getElementById("zaq-widget");
let conversationId = sessionStorage.getItem("zaq-conversation-12");

frame.addEventListener("zaq:conversation", ({ detail }) => {
  conversationId = detail.conversation_id;
  sessionStorage.setItem("zaq-conversation-12", conversationId);
});

async function authenticateWidget() {
  // Implement this endpoint on your website's authenticated backend.
  const response = await fetch("/api/widget-identity", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ conversation_id: conversationId }),
    cache: "no-store"
  });
  if (!response.ok) throw new Error("Widget identity unavailable");
  const { identity_token } = await response.json();
  await zaq.widget.init({ identity_token });
}

frame.addEventListener("zaq:authentication-required", () => {
  authenticateWidget().catch(console.error);
});
await authenticateWidget();
```

Clear stored conversation IDs on logout/account changes; ZAQ still authorizes
every resume. The backend must derive `user_id` from its authenticated session,
validate requested conversation/context inputs, then sign all three fields.
The frontend cannot override them in `init`. Signed prompt context remains ordinary
user input, not privileged instructions. Use your backend's normal CSRF protection
for its signing endpoint. Old identity-only tokens are rejected; mint fresh tokens
as JWTs with the signed initialization schema.
Opening the widget creates no conversation. The first accepted question supplies
the ID through `zaq:conversation`; full reloads use that ID and a fresh proof.
Unknown/foreign/deleted conversations fail without creating a replacement.

Proofs expire within five minutes. Nonces are consumed atomically per LiveView
process; another connection must obtain a fresh proof. The replay cache is
node-local and volatile, while surviving connector replacement. Use this built-in
verifier for the single-node smoke; a clustered/durable replay policy requires a
custom verifier. Runtime replacement/rotation and expiry revoke connected sessions
and subscriptions. Renewal cannot change an iframe's verified sender.

On token expiry, the existing chat and unsent draft remain visible, with sending
disabled, while the parent requests a new token. A successful init restores
authorized history and enables sending without remounting the composer. Failed
renewal leaves sending blocked; connector revocation/replacement still clears the
view. Previously expiry cleared `parent_context` and messages, removing the React
root before token issuance completed and causing a visible blink. Browser coverage
now verifies composer DOM identity and draft preservation across real expiry and
renewal using a short-lived test token.

Resume loads the first 50 canonical messages and preserves their transcript
positions separately. Pagination UI and longer-transcript acceptance are outside
this first smoke. Timeouts are unknown outcomes: the widget blocks further sends
until explicit reinitialization/history recovery and never automatically resends.

`init` accepts only `{identity_token}`. Its signed application fields are exactly
`user_id`, `conversation_id` and `prompt_context`; the signing helper fills omitted
optional fields with nil. Unknown claims and unsigned initialization fields fail
closed. Any future init field must be explicitly added to the signed schema.
Settings and per-instance stylesheet params are not initialization fields.
Apply presentation separately:

```javascript
await zaq.widget.updateSettings({ theme: "dark", language: "fr" });
```

The shared LiveView fixture covers authentication, lazy creation, queued streaming,
correlation, resume, expiry, revocation and failure. The browser test
`assets/tests/shared-widget.spec.ts` exercises the generated installation script
and signed bootstrap over the real LiveView transport. The constructor smoke loads
the actual sibling ZAQ contract. These checks do not call a live agent/model;
configure your agent and backend identity endpoint for that acceptance test.
