# Integrate the ZAQ Web Widget on your website

This guide is for the developer of the website that displays the widget. The website's **backend** authenticates its visitor and signs a short-lived identity JWT. The website's **frontend** loads ZAQ's installation script and passes that JWT to `zaq.widget.init`. ZAQ verifies the JWT before accepting chat messages. Your website never needs to implement the widget's WebSocket or `postMessage` protocol.

## 1. Configure the widget in ZAQ

In ZAQ's back office, open **Channels → Communication → Web Widget** (`/bo/channels/retrieval/web_widget`) and create a configuration:

1. Give it a name, select the routing or default agent you want, and enable it.
2. Add each exact website origin to **Allowed embedding origins**, one per line, for example `https://www.example.com`. Include the scheme and a nondefault port; omit the path and trailing slash. Add development and staging origins separately. An empty list prevents embedding.
3. Save the configuration, then generate its **Authentication key**. Copy the key into your website backend's secret store; ZAQ displays it only once. Rotating it invalidates tokens signed with the old key.
4. Copy the **Installation script** for this configuration. Its public `data-widget-id` is the numeric connector ID. It is safe to put in HTML; the authentication key is not.

ZAQ must expose the script, iframe route, and LiveView socket from the URL in the installation script (`/web_widget/assets`, `/widget/:id`, and `/live`). Use HTTPS on a public website. The origin in the script is ZAQ's public base URL, not the website origin you added to the allowlist. If you use a tunnel for local ZAQ, use the tunnel URL as ZAQ's public base URL; add the **website's** origin to the allowlist.

The current ZAQ host configuration opts into connector-key verification and sets the expected JWT issuer and audience:

```elixir
config :web_widget, :integration,
  pubsub_server: Zaq.PubSub,
  identity_verifier: :connector_key,
  identity_issuer: "test-widget",
  identity_audience: "zaq-web-widget"
```

These are ZAQ server settings, not values to put in `zaq.widget.init`. The issuer and audience are public matching values; the authentication key is the secret. If your ZAQ deployment uses different issuer or audience values, use those exact values when signing.

## 2. Sign a JWT on your website backend

Store the copied authentication key as `ZAQ_WIDGET_SECRET` on your **backend only**. It is the HS256 HMAC secret, used as its exact UTF-8 bytes. Do not Base64-decode it, use it as a Phoenix.Token salt, return it from an API, or put it in JavaScript or HTML. Any backend language with a standards-compliant JWT library can sign the token.

The token must have exactly this protected header:

```json
{"alg":"HS256","typ":"JWT"}
```

Its payload contains these claims (the example widget ID `12` must match your ZAQ configuration):

| Claim | Value |
| --- | --- |
| `widget_id` | Positive integer connector ID, such as `12`, not a string. |
| `user_id` | Nonblank external user ID from your authenticated backend session (up to 255 UTF-8 bytes). |
| `conversation_id` | An authorized existing conversation ID, or JSON `null` for a new conversation. |
| `prompt_context` | Optional plain text for the agent, or JSON `null` (up to 100,000 UTF-8 bytes). |
| `iss` | Exact `identity_issuer` configured in ZAQ. |
| `aud` | Exact `identity_audience` configured in ZAQ, as a string. |
| `iat` | Current Unix time in integer seconds. |
| `exp` | Integer Unix time after `iat`, at most 300 seconds later. |
| `jti` | Fresh random ID for this token, 16–255 characters; a UUID works. |

ZAQ rejects missing or unknown claims, expired/future-issued tokens, and algorithms other than HS256. Keep backend and ZAQ clocks synchronized. A JWT is signed but readable by the browser, so `prompt_context` must not contain secrets or privileged instructions.

Here is a Node.js signing function using [`jose`](https://github.com/panva/jose) (`npm install jose`). The same claims and algorithm work in Python, PHP, Go, and other languages:

```js
import { SignJWT } from "jose";
import { randomUUID } from "node:crypto";

const widgetId = 12; // Replace with the ID in the ZAQ installation script.
const secret = process.env.ZAQ_WIDGET_SECRET;
if (!secret) throw new Error("ZAQ_WIDGET_SECRET is missing");
const key = new TextEncoder().encode(secret);

async function issueWidgetIdentity(userId, conversationId, promptContext) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    widget_id: widgetId,
    user_id: String(userId),
    conversation_id: conversationId ?? null,
    prompt_context: promptContext ?? null,
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer("test-widget") // Must match ZAQ identity_issuer.
    .setAudience("zaq-web-widget") // Must match ZAQ identity_audience.
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .setJti(randomUUID())
    .sign(key);
}
```

Expose an authenticated `POST /api/widget-identity` endpoint on **your website backend**. Use your normal session and CSRF protection. Derive `user_id` from that session, not from the request body. Accept a requested `conversation_id` only after confirming that the session's user may resume it; return an error for foreign or deleted conversations. Treat any page-supplied `prompt_context` as untrusted text, validate its length, or derive it on the backend. For each request, call `issueWidgetIdentity(...)` and return `{"identity_token":"<signed JWT>"}` with `Cache-Control: no-store`. If anonymous chat is intended, your backend still needs to establish a stable anonymous visitor session and assign its user ID there.

## 3. Install the script and initialize the iframe

Paste the exact script ZAQ generated into your website layout, once per page. For example:

```html
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js" data-widget-id="12" defer></script>
```

The script automatically creates `<iframe id="zaq-widget">`. You do not need to write iframe markup or include another widget script. In your website's existing JavaScript, run the code below after `embed.js` has loaded (for example, on `DOMContentLoaded`). It obtains a JWT from **your backend** and passes only the token to the widget. It also saves the conversation ID for page reloads and renews the token when the widget asks. Adapt storage and request headers to your website's session and CSRF setup:

```js
const frame = document.getElementById("zaq-widget");
const conversationKey = "zaq-conversation-12";
let conversationId = sessionStorage.getItem(conversationKey);
let authenticating;

frame.addEventListener("zaq:conversation", (event) => {
  conversationId = event.detail.conversation_id;
  sessionStorage.setItem(conversationKey, conversationId);
});

function authenticateWidget() {
  if (authenticating) return authenticating;
  authenticating = (async () => {
    const response = await fetch("/api/widget-identity", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" }, // Add your CSRF header if required.
      body: JSON.stringify({
        conversation_id: conversationId,
        prompt_context: `Current page: ${location.pathname}`,
      }),
      cache: "no-store",
    });
    if (!response.ok) throw new Error("Widget identity unavailable");
    const { identity_token } = await response.json();
    await zaq.widget.init({ identity_token });
  })().finally(() => { authenticating = undefined; });
  return authenticating;
}

frame.addEventListener("zaq:authentication-required", () => {
  authenticateWidget().catch(console.error);
});
authenticateWidget().catch(console.error);
```

Only `{ identity_token }` belongs in `init`. Do not pass `user_id`, `conversation_id`, `prompt_context`, settings, or the authentication key there; the first three live inside the signed token. The widget creates a conversation when the first question is accepted and emits `zaq:conversation` on the iframe with `{ conversation_id }`. Keep that ID for resume, but always reauthorize it on your backend. Clear it on logout or account change. A fresh page load needs a fresh JWT; a token cannot be reused by a different widget connection.

Tokens last at most five minutes. On expiry the widget keeps the existing chat and draft visible but pauses sending, then emits `zaq:authentication-required`. Fetch and sign a **new** JWT and call `init` again, as above. If renewal fails, leave the widget read-only until the website can authenticate again. The widget will not silently switch the user on an existing iframe; reload it when changing accounts.

## 4. Read and change presentation settings

Theme and language are separate from identity. Once the script has loaded, use:

```js
const current = await zaq.widget.getSettings();
console.log(current); // { theme: "light", language: "en" } initially

await zaq.widget.updateSettings({ theme: "dark" });
await zaq.widget.updateSettings({ language: "ar" });
await zaq.widget.updateSettings({ theme: "auto", language: "fr" });
```

`theme` accepts `"light"` (default), `"dark"`, or `"auto"` (follow browser appearance). `language` accepts `"en"` (default), `"fr"`, or `"ar"` (right-to-left). An update changes only supplied fields and preserves the conversation. Both methods return promises and reject invalid settings or time out after 20 seconds. The parent client reapplies accepted settings after an iframe reconnect; persist website preferences yourself if they must survive a full page reload. Do not add settings to the JWT or to `init`.

## First smoke test

1. Enable the connector and make sure your website origin is allowed. Open the script URL directly if `embed.js` fails to load.
2. Load your website. Confirm it has one `#zaq-widget` iframe and that your backend's identity endpoint returns a JWT, not the authentication key.
3. Send a message. Confirm the ZAQ agent replies and `zaq:conversation` supplies an ID. Reload the page to check resume, then wait for renewal or use a short-lived test token to check `zaq:authentication-required`.
4. Try `getSettings()` and `updateSettings({ theme: "dark" })` in the parent page console.

If initialization fails, check that the connector is enabled; widget ID, secret, issuer, audience, clock, and exact allowed website origin match; and the requested conversation belongs to the signed user. For operator diagnostics and the current limitation of ZAQ tool activity, see [authenticated chat smoke](authenticated-chat.md). For package hosting details, see [host integration](host-integration.md).
