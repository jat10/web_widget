# Phoenix host integration

## Integration status

Routing and assets below are implemented package capabilities. The selected ZAQ
integration targets shared protocol v1 at revision
`c38e7e4e5`. The package runtime builder, verified
server session, shared ingress, LiveView response encoding and signed bootstrap
are implemented. Start with the [authenticated chat smoke](authenticated-chat.md).
Follow the
[adapter contract](adapter-contract.md) and [wiring plan](exec-plans/wiring-widget.md).
The existing mock host is not a working ZAQ installation.

## Current local ZAQ mount

By explicit user request, the local ZAQ checkout now imports `WebWidget.Router`,
mounts `web_widget("/widget")` in its browser pipeline outside BO authentication,
and serves installed widget assets through its existing static plug.
Run the library-provided `mix web_widget.assets.install` from ZAQ after building the widget
bundle. ZAQ includes `web_widget` in `static_paths/0` and does not need a
`WebWidget.Static` plug or a local Mix task. Restart ZAQ after recompilation.
The same ZAQ endpoint serves `/widget/<id>`, `/web_widget/assets/` and `/live`.
Point ngrok at ZAQ's HTTP port (normally 4000), and use that public origin as the
global base URL. Omit `integration.public_url` or use that same origin; no separate
widget endpoint on 4012 is required in this topology. Widget 12 must be enabled
and allow the parent page's exact origin, `http://localhost:4010`.

The alternate configuration-only topology below remains available but is not
needed for this local setup. Authentication/chat migration is still milestone 2.

## ZAQ configuration-only endpoint

Do not edit ZAQ's endpoint/router. The package can start its own endpoint once,
without its Repo, demo runtime or DNS cluster:

```elixir
config :web_widget, start_web_server: false, start_integration_server: true

config :web_widget, WebWidgetWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost", port: 4012, scheme: "http"],
  http: [ip: {127, 0, 0, 1}, port: 4012],
  secret_key_base: System.fetch_env!("WEB_WIDGET_SECRET_KEY_BASE"),
  live_view: [signing_salt: "widget-live"],
  pubsub_server: WebWidget.PubSub,
  server: true
```

Use a securely generated endpoint secret (at least 64 bytes). Dependency config
files are not imported; the host must supply these endpoint options. Keep normal
socket origin checking enabled. For a separate endpoint, add
`public_url: "http://localhost:4012"` to the integration options below. Use an
HTTPS public origin in production. Paths, credentials, queries and fragments in
this URL are unsupported. If `public_url` is omitted, the supplied ZAQ global
base URL is used; configure a reverse proxy for `/widget`, `/web_widget/assets`
and `/live` to the package endpoint. The snippet cannot install proxy routes.

In BO at `/bo/channels/retrieval/web_widget`, save a disabled connector, set exact
parent origins and agent routing, and generate/provision its key server-side.
Set the global base URL in System Configuration before enabling. The adapter
implements both `build/2` and `embed_script/2`, which BO requires for availability.
Copy the installation snippet:

```html
<script src="http://localhost:4012/web_widget/assets/embed.js" data-widget-id="42" defer></script>
```

The script creates `#zaq-widget` and applies the existing frame layout. An optional
`iframe-location-id="#my-widget-container"` selects an existing div with a parent-supplied
height; the iframe fills it without taking over the page or locking parent scrolling.
When the container itself is `#zaq-widget`, the iframe uses `#zaq-widget-frame`.
It does
not fabricate identity or initialize an authenticated chat. The current
`zaq.widget.init({user_id})` API remains a mock/demo API; verified bootstrap and
shared-response rendering remain milestone 2. No key belongs in this snippet.
The package endpoint opt-in does not imply that chat authentication is complete.

## Generic Phoenix host mounting (not required for ZAQ)

### Install assets into the host

The library includes `Mix.Tasks.WebWidget.Assets.Install`. After compiling the dependency,
run this command **from the host project**:

```sh
mix web_widget.assets.install
```

It copies all built JS/CSS and supporting files from the dependency's
`priv/static/assets` into the host's `priv/static/web_widget/assets`, including
`embed.js`. Build the widget bundle first (`npm --prefix assets run build` from
the library checkout); an incomplete bundle raises an actionable error.
Add `web_widget` to the host's existing static-path allowlist. Its standard
`Plug.Static` then serves the existing `/web_widget/assets/...` URLs, so remove
the optional `WebWidget.Static` plug. Host `assets/app.js` and CSS are untouched.
Ignore `/priv/static/web_widget/` in the host's Git configuration.

Repeat installation after rebuilding/upgrading the widget, and run it before
`mix phx.digest` when preparing a release. Hosts may add the command to their
build/deploy aliases; the task does not edit host source or build aliases.

### Mount the router and optionally serve dependency assets directly

Mount in the host browser pipeline, outside any existing `live_session` (the
macro creates its own). The default prefix is `/widget`; a custom prefix or
aliased scope is also supported.

```elixir
import WebWidget.Router

scope "/" do
  pipe_through :browser
  web_widget("/widget")
end
```

The browser pipeline must fetch session and LiveView flash, protect against CSRF,
and set secure browser headers. Keep the host's `Plug.Session` and LiveView socket
at `/live`, using the same session options in
`websocket: [connect_info: [session: @session_options]]`. Add this before the host
router and any catch-all static plug:

```elixir
plug WebWidget.Static
plug MyAppWeb.Router
```

The macro supplies an iframe root layout loading JS/CSS and lazy React chunks
from `/web_widget/assets/`. The bundle registers `WidgetContext` and LiveReact's
`ReactHook` and connects to the host's `/live` socket. Widget hooks run inside the iframe. The embedding website separately loads
`/web_widget/assets/embed.js` to expose the parent-side `zaq.widget` API. The iframe does not load the host app
bundle. Currently the endpoint must be root-mounted with the standard `/live` path.

For hosts choosing manual mounting, mount outside authenticated live sessions. Parent identity is verified
by the adapter before shared Context construction, independently of BO login.
Keep normal socket origin checks: the iframe connects to its own host origin;
`allowed_domains` governs the parent embedding origin.

## Configure the ZAQ runtime

For local development, add `{:web_widget, path: "../web_widget"}` to ZAQ's
dependencies and resolve compatible Phoenix/LiveView/LiveReact versions. Configure
this entry in the existing Channels map, preserving the other providers:

```elixir
web_widget: %{
  bridge: Zaq.Channels.WebBridge,
  runtime_builder: WebWidget.Integration.RuntimeBuilder
}
```

The builder implements `build(config, hooks)` and returns
`{:ok, {state_spec_or_nil, listener_specs}}` or `{:error, reason}`.
ZAQ's existing BridgeSupervisor owns child startup/restart/teardown. Do not manually
start a second widget runtime alongside it.

Use one enabled `web_widget` connector per widget. Its persisted positive integer
ID is the trusted Context/Delivery configuration ID; its string form is the route
and registry ID, for example `/widget/42`. Configure `display_name`, exact
`allowed_domains`. Do not persist `stylesheet_url`. Browser initialization currently
accepts only the signed three-field bootstrap; stylesheet params are not supported.
Do not add a separate widget ID, theme or language setting. Keep multiple
conversations disabled for this first integration.

Retain the trusted constructor hooks and config-bound sink in server state. Supply
`Zaq.PubSub` and the identity verifier through trusted adapter application
configuration; hooks do not contain a PubSub server. The application configuration
to add when installing in ZAQ is:

```elixir
config :web_widget, :integration,
  public_url: "http://localhost:4012",
  pubsub_server: Zaq.PubSub,
  identity_verifier: {MyApp.WidgetIdentity, :verify, []}
```

`MyApp.WidgetIdentity` is an application-owned verifier to implement, not supplied
by the package. It receives `(proof, %{widget_id: string_id, channel_config_id: id})`
after any configured prefix arguments, verifies proof and scope, and returns
`{:ok, %{sender_id: external_id, expires_at: unix_seconds, init: verified_init}}`
or `{:error, reason}`. `verified_init` contains only `user_id`, `conversation_id`
and `prompt_context` from the verified proof. Omitting it permits only a fresh
conversation with nil prompt context; browser input cannot supply overrides.
It must not accept an unchecked browser ID. Absent verifier/PubSub configuration
or invalid hooks fail builder construction. `build/3` accepts explicit options
for tests without changing application environment.

## Origins and runtime availability

Origins must be exact HTTP(S) origins, including any non-default port. Paths,
wildcards, credentials, queries, and fragments are rejected; a trailing slash is
normalized. Missing, null, or empty `allowed_domains` disables the widget, including
same-origin embedding. The route sets CSP `frame-ancestors` from this list and
removes `X-Frame-Options`; unavailable widgets use `frame-ancestors 'none'`.
The browser bootstrap also checks the parent window and allowed origin.
Reload existing iframes after changing origin configuration. The standalone demo
explicitly allows `http://localhost:4000` in development.

For local testing, override the demo origins when starting the development server:

```sh
WEB_WIDGET_DEMO_ALLOWED_DOMAINS=http://localhost:4010 mix phx.server
```

Use a comma-separated list to allow multiple origins. This development-only
override replaces the demo allowlist and requires restarting the server.

Widget IDs are globally unique.
HTTP and connected mounts look up the ID afresh. Missing/stopped runtimes render
“Widget unavailable” without chat hooks and reject browser events. This is an
HTTP 200 error screen, not a redirect or HTTP 404. Currently runtime changes do not
revoke already-mounted views; reconnect/remount checks again. ZAQ integration must
also revoke connected-session access, as required by the adapter contract. The resolved display name
supplies the document title and conversation header.

Incomplete or malformed paths under the mounted widget prefix (such as `/widget`
or `/widget/support/extra`) return a friendly HTTP 404 without debug details or
chat scripts. Their framing policy remains `frame-ancestors 'none'`. Embedding
pages should show their own unavailable message when a frame cannot load or
does not announce readiness; browsers do not display denied iframe content.

## Shared callback and server session (LiveView migration pending)

Verify parent identity server-side before constructing Context, subscribing,
loading history or submitting a question. A browser `user_id` and allowed origin
are insufficient. Verification/key provisioning belongs to the adapter/host,
not a `widget.authenticate` command in ZAQ's shared protocol.

Construct shared payloads and trusted Context/Delivery through the supplied hooks.
Invoke the config-bound MFA with its configured arguments first:

```elixir
{module, function, args} = hooks.sink_mfa
apply(module, function, args ++ [payload, [context: verified_context]])
```

Commands return a semantic Response directly, async questions return
`{:ok, Response}` acceptance, and sync questions return one terminal Response.
Handle pre-acceptance `{:error, reason}` and semantic error responses explicitly.
Do not use the current mock callback's event-first argument order or `:ok` receipt.

Fresh init means readiness with no conversation creation. Subscribe to a private,
server-generated session destination on `Zaq.PubSub` before submitting the first
question; include it in trusted Delivery. Consume
`{:web_response, adapter_event_name, response}` and encode the public `response.*`
UI events once. Bind the first accepted conversation ID from the correlated receipt.
Do not route ZAQ replies through the old `Adapter.send_event/1` conversation topic.

Preserve request/message correlation, full-text streaming replacement and safe
failure/timeout handling. Reverify and authorize resume, then restore canonical
history without reseeding parent context or automatically retrying questions.
See the [contract](adapter-contract.md) for the complete lifecycle.

## Build and release assets

Dependency configuration files are not imported by Phoenix. The application
starts only its runtime registry by default, without the standalone endpoint,
Repo or demo runtime. Do not enable `config :web_widget, start_web_server: true`
in the host. Widget rendering explicitly disables React SSR; no Node SSR service
or global LiveReact setting is needed.

Build assets before assembling the host release. With the normal Mix `deps/`
layout, run from the host root (Node 22.12+ or 24 and npm required):

```sh
mix deps.get
# Only if deps/web_widget/deps does not exist: expose host-resolved JS packages.
ln -s .. deps/web_widget/deps
npm --prefix deps/web_widget/assets ci
npm --prefix deps/web_widget/assets run build
mix compile
```

For path/umbrella dependencies, point the widget's `deps` symlink at the host's
actual dependency directory. Existing widget-local Phoenix/LiveView/LiveReact
dependencies must match the host's resolved versions. Keep the generated
`web_widget/priv/static/assets` directory in the release. Rebuild after dependency
or UI changes. Static responses revalidate with ETags.

Embed `/widget/<connector-id>` on a configured allowed origin. The existing
[website examples](../README.md#add-the-widget-to-your-website) demonstrate the
embed script, readiness, settings and resizing. The
[signed bootstrap guide](authenticated-chat.md) covers backend proof issuance
and the configuration needed before real ZAQ use.

## Baseline and acceptance

From the sibling ZAQ root, the existing host baseline is:

```sh
mix test test/zaq/channels/web/widget_conformance_test.exs
```

Milestone 0 ran it successfully: 2 tests, 0 failures. This fixture exercises ZAQ's
shared protocol and deterministic LLM HTTP boundary; it does not load the real
package endpoint or prove parent identity/session security. The wiring plan adds
real-package smoke coverage followed by authenticated iframe acceptance. The
current widget Playwright suite uses mock hosts and cannot replace those checks.

The package also provides an optional constructor-compatibility smoke. From this
repository root, with the pinned sibling ZAQ checkout available:

```sh
MIX_ENV=test mix run --no-start test/support/integration/shared_protocol_smoke.exs ../zaq
```

It loads the actual shared constructor modules and stylesheet validator from that checkout into an
isolated package VM. It starts the real package runtime through the builder,
verifies a test session, constructs readiness/question/Delivery/Context values and
checks a fixture receipt and PubSub terminal. It also checks real constructor
rejection of malformed input. It uses a test-only verifier and sink, starts no ZAQ
application or database, and does not modify ZAQ or add a reverse dependency.
This verifies package/constructor compatibility, not host routing, persistence,
real agent execution or iframe acceptance.


### Configuration-only host runtime check

The local ZAQ checkout is configured with the path dependency, package builder,
`Zaq.PubSub` and `{WebWidget.Integration.UnconfiguredIdentity, :verify, []}`.
That package-owned verifier rejects every proof while allowing runtime startup;
replace it with a real verifier before chat use. No ZAQ modules or tests were
changed. Restart a running ZAQ instance before checking newly installed runtimes.

From ZAQ, run the package-owned lifecycle smoke:

```sh
MIX_ENV=test mix run ../web_widget/test/support/integration/host_runtime_smoke.exs
```

It verifies enable/change/disable/re-enable and exact settings/hooks delivery
using synthetic configs through the existing CommunicationBridge lifecycle.
It does not write saved channel records or start a second listener/endpoint.
The host owns one runtime state child; listener specs are empty by design.
The smoke passes against the updated BO contract (1 test, 0 failures).
A separate rollback-only BO smoke uses the actual package builder:

```sh
MIX_ENV=test mix run ../web_widget/test/support/integration/host_bo_smoke.exs
```

It verifies create/key generation/agent routing/enable/snippet/settings restart/
rotation/disable/re-enable. Signed proof and shared-response LiveView wiring
are now implemented in the package; live agent acceptance remains separate. See the wiring plan for the upstream baseline test runner:
upstream tests expecting an absent adapter must run separately from this installed
package smoke.
