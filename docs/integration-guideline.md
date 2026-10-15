# Integrate the ZAQ Web Widget on your website

This guide is for website developers embedding an already-deployed ZAQ widget.
Your backend authenticates the visitor and issues a signed identity JWT; the
installation script fetches it, mounts the widget, and renews authorization.
ZAQ deployment and package configuration belong in [host integration](host-integration.md).

## Configure ZAQ

Create and enable a Web Widget connector in **Channels → Communication → Web Widget**. Add each exact website origin to **Allowed embedding origins**. An empty list denies embedding. Save the generated authentication key in your website backend's secret store. Its public numeric connector ID appears in the installation script.

Copy the generated installation snippet and note the connector's **Identity issuer**
and **Identity audience**. The examples use `zaq_issuer` and `zaq_audience`; substitute
your actual configured values. Keep the key on the backend and use its exact UTF-8
bytes for HS256; do not Base64-decode it.

Use HTTPS. For embedding across different sites, ask your ZAQ administrator to
configure a compatible cookie policy (normally SameSite `None`). Browser cookie
restrictions can still prevent embedding.

## Issue identity tokens

The protected header is exactly `{"alg":"HS256","typ":"JWT"}`. The decoded JWT
payload supports only these claims:

| Claim | Required | Value |
| --- | --- | --- |
| `widget_id` | Yes | Positive integer connector ID, not a string. |
| `user_id` | Yes | Backend-authenticated, nonblank, trimmed UTF-8 string, 1–255 bytes. |
| `iss` | Yes | Exact configured identity issuer. |
| `aud` | Yes | Exact configured identity audience, a string rather than an array. |
| `iat` | Yes | Integer Unix-second issue time, not in the future. |
| `exp` | Yes | Integer Unix-second expiry, strictly after `iat`. |
| `jti` | Yes | Fresh random token identifier, 16–255 characters; use a UUID or random URL-safe string. |
| `nbf` | No | Integer Unix-second not-before time, enforced when present. |
| `profile` | No | Backend-sourced profile object described below; null or omission means no profile. |

For example (replace identifiers and timestamps with your actual values):

```json
{
  "widget_id": 12,
  "user_id": "customer-123",
  "iss": "zaq_issuer",
  "aud": "zaq_audience",
  "iat": 1792065600,
  "exp": 1792069200,
  "jti": "83d5d49d-2d2c-46f9-8d57-97b213ef912a",
  "profile": {
    "full_name": "Ada Example",
    "email": "ada@example.com",
    "phone": "+33123456789"
  }
}
```

Unknown claims, including `conversation_id`, `prompt_context`, and settings, are
rejected. The default maximum lifetime is **seven days**; confirm the lifetime with
your ZAQ administrator if customized. Keep backend and ZAQ clocks synchronized.
Mint a fresh JWT for every token-endpoint request: initial use must occur within
five seconds by default. Do not cache or reuse tokens across iframe page loads.

### Optional verified profile

`profile` accepts only the following fields; each may be omitted or `null`:

| Field | Validation |
| --- | --- |
| `full_name` | At most 255 bytes. |
| `email` | At most 254 bytes; one `@`, a dotted domain, and no whitespace. |
| `phone` | International form: `+` followed by 7–15 digits, first digit nonzero. |

All supplied values must be nonblank, already trimmed UTF-8 strings without ASCII
control characters. Unknown profile fields or invalid values reject the entire
credential. A missing, null, empty or all-null profile preserves user-ID-only
authentication. Values are preserved rather than case-folded or reformatted.

Derive profile values from the backend's authenticated account records, **never
arbitrary browser parameters**. The signature asserts your backend's provenance;
the widget does not independently verify email or phone ownership. A JWT is signed,
not encrypted, and is readable by the browser. Include only the supported contact
fields you intend to share with ZAQ.

ZAQ uses the profile to enrich its People records, including email/phone matching.
On renewal, issue the current profile again; omission means subsequent requests
from that renewed session carry no profile. This does not delete existing People
records. The [profile contract](adapter-contract.md#verified-sender-profiles) covers
host-side behavior.

### Token endpoint example

For a Node backend, install `jose` with `npm install jose`:

```js
import { SignJWT } from "jose";
import { randomUUID } from "node:crypto";

const key = new TextEncoder().encode(process.env.ZAQ_WIDGET_SECRET);

async function issueWidgetToken(authenticatedUser) {
  const now = Math.floor(Date.now() / 1000);
  // authenticatedUser comes from your backend session/account records.
  // Omit profile entirely if no verified contact enrichment is needed.
  return new SignJWT({
    widget_id: 12,
    user_id: String(authenticatedUser.id),
    profile: {
      full_name: authenticatedUser.full_name ?? null,
      email: authenticatedUser.email ?? null,
      phone: authenticatedUser.phone ?? null
    }
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer("zaq_issuer")
    .setAudience("zaq_audience")
    .setIssuedAt(now)
    .setExpirationTime(now + 604800)
    .setJti(randomUUID())
    .sign(key);
}
```

Create a **same-origin** authenticated `GET /api/widget-token` endpoint on your website. It should return `{"identity_token":"<JWT>"}` with `Cache-Control: no-store`. Use the website's normal session protection. Do not accept a user ID or connector key from the browser. Give an anonymous visitor a stable backend session if anonymous chat is intended.

## Install and use the widget

Use ZAQ's generated installation snippet and preserve its URLs, particularly for
scoped/custom deployments. Add the script once per page. If the generated script
omits `data-token-url`, add it or ask the ZAQ host to configure `token_url` for the
generated snippet. It is a same-origin URL on **your website**, not ZAQ:

```html
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="12"
        data-widget-url="https://YOUR-ZAQ-HOST/widget/12"
        data-token-url="/api/widget-token" defer></script>
```

Optional `iframe-location-id="#support-chat"` fills an existing div (give it a
height); without it the widget floats. Optional `stylesheet-url` loads your custom
stylesheet. Prefer a target ID other than `zaq-widget` to keep the iframe ID used
by the examples below.

The script fetches a fresh token and renews authorization automatically without
clearing drafts or streaming responses. The connector key never reaches the
browser. Custom token providers and manual mounting are documented in
[authenticated chat](authenticated-chat.md).

## Optional: restore conversations

Opening the widget creates no conversation. To resume, retain the ID emitted in `zaq:conversation`, then call `updateContext` after public readiness. ZAQ checks that the verified user may resume it; unknown or foreign IDs fail without creating a replacement. Plain prompt context is sent only with the first question of a new conversation and is not identity or routing authority.

```js
// Run in a module script after the installation script has loaded.
const frame = await new Promise(resolve => {
  const existing = document.getElementById("zaq-widget");
  if (existing) return resolve(existing);
  const observer = new MutationObserver(() => {
    const mounted = document.getElementById("zaq-widget");
    if (mounted) { observer.disconnect(); resolve(mounted); }
  });
  observer.observe(document.body, { childList: true });
});
const key = "zaq-conversation-12";
frame.addEventListener("zaq:conversation", event => {
  sessionStorage.setItem(key, event.detail.conversation_id);
});
async function restore() {
  const conversation_id = sessionStorage.getItem(key);
  if (conversation_id) await zaq.widget.updateContext({ conversation_id });
  else await zaq.widget.updateContext({ prompt_context: `Current page: ${location.pathname}` });
}
frame.addEventListener("zaq:ready", () => { void restore().catch(console.error); });
if (zaq.widget.isReady()) void restore().catch(console.error);
```

Clear the stored ID on logout or account change. Changing the verified user
requires a new iframe page and fresh token. Normal network reconnects are handled
automatically. On expiry, sending pauses until authorization is renewed; messages
with an unknown submission outcome are never automatically resent.

The iframe emits `zaq:ready`, `zaq:authenticated`, `zaq:authentication-required`, `zaq:disconnected`, and `zaq:conversation` on the iframe element. Inspect `event.detail.reason` for failures such as `expired`, `store_unavailable`, or `backend_revoked`. Backend revocation is terminal for that iframe: the widget displays “Refresh the page to reconnect.” and closes its LiveView transport. The parent client stops requesting tokens until a page refresh.

## Optional: presentation

```js
await zaq.widget.updateSettings({ theme: "dark", language: "ar" });
const settings = await zaq.widget.getSettings();
```

Theme accepts `light`, `dark`, or `auto`; language accepts `en`, `fr`, or `ar`. Accepted settings are reapplied after an iframe reload by the parent client. Persist website preferences yourself across full website page loads.

## Optional: backend disconnect

On logout or an administrative revocation, the website backend can call `POST https://YOUR-ZAQ-HOST/widget-api/12/disconnect` with JSON `{"user_id":"<authenticated user>"}` and `Authorization: Bearer <control proof>`. The proof is a separate HS256 JWT with exactly `iss`, control `aud`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat` and `exp`, and random `jti`. Its lifetime is at most 30 seconds by default. The path, body, and proof must agree. A browser identity JWT cannot authorize this request.

The control audience is your identity audience plus `:control`. For a Phoenix
backend, sign it with:

```elixir
WebWidget.Integration.ControlProof.sign(connector_key, 12, user_id,
  issuer: "zaq_issuer", audience: "zaq_audience:control")
```

Substitute your configured issuer and audience. Reuse the **same proof** when
retrying one disconnect operation. A new identity token may need to be issued in
the second after revocation. If ZAQ uses a deployment prefix, obtain the matching
disconnect URL from its administrator.

## First smoke test

Verify the script and token endpoint return successfully, `#zaq-widget` appears once, a first question gets a `zaq:conversation` ID, and a page reload restores that ID. Test renewal with a short test lifetime, then call backend disconnect and confirm the refresh message. See [authenticated chat smoke](authenticated-chat.md) for operational checks and [host integration](host-integration.md) for package mounting.

If using profiles, also verify the initial signed profile reaches ZAQ's People
enrichment, changed fields arrive after successful renewal, and user-ID-only tokens
still work. Malformed profiles and tampered tokens must fail authentication rather
than silently becoming trusted contact data.
