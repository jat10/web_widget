# Phoenix host integration

`web_widget` is a dependency of the host application. The host supplies connector configuration, trusted shared-protocol constructors, a config-bound sink callback, its PubSub server, and the serving endpoint with the package's scoped LiveView socket. ZAQ owns routing, permissions, identity resolution, and durable conversations. The package owns iframe delivery, signed identity verification, page binding, browser state, and host response delivery to the correct widget. It has no compile-time ZAQ dependency.

## Explicit supervision and configuration

### Generic host boundary

Register `WebWidget.HostAdapter` as the provider adapter. The host dynamically
delegates these four callbacks without constructing widget-specific hooks or
translating the package readiness protocol:

```elixir
{:ok, infrastructure} = WebWidget.HostAdapter.infrastructure_child_specs(host_opts)
{:ok, {connector_spec, listeners}} = WebWidget.HostAdapter.build_runtime_specs(config, hooks)
{:ok, status} = WebWidget.HostAdapter.ingress_status(config, timeout_ms: 2_000)
{:ok, snippet} = WebWidget.HostAdapter.installation(config, base_url, [])
```

`infrastructure` is the shared singleton's OTP spec list; install it once.
`connector_spec` is an independent supervisor child. Install it with the host's
ordinary DynamicSupervisor; terminate/replace its returned PID to remove/change it.
`listeners` is currently empty. Hooks contain exactly `message`, `command`,
`context`, `delivery`, `response` constructor modules plus a fixed config-bound
`sink_mfa`. Widget identity comes from `config.id`, presentation from `config.settings`;
`display_name` falls back to `config.name`. No host-specific module is referenced
by this package. Raw `WebWidget` and `WebWidget.Connector` remain public for direct
compositions, and `RuntimeBuilder.status/2` deliberately retains raw version-2
observation compatibility.

Ingress returns closed keys `status`, `mode`, `summary`, `reason`, `checks`,
`effective_settings`, `verification`; statuses are `:ok`, `:pending`, `:error`,
`:unknown`, `:disabled` and mode is `"websocket"`. The adapter compares desired
issuer/audience/SameSite with installed evidence and bounds the whole probe to
1–2,000 milliseconds. No credentials, constructors or raw exceptions escape.
Installation accepts a positive ID or resolved config and optional `public_url`,
`token_url`, `widget_path`, `scope`; `[]` works with running defaults or offline package
defaults. It generates escaped, secret-free markup, not executable BO content.

The OTP dependency starts required libraries, including Mnesia, but **no widget
processes or listeners**. Do not disable its dependencies with `runtime: false` or
`app: false`. Add this child to your host supervisor before connector runtimes:

```elixir
children = [
  {Phoenix.PubSub, name: MyHost.PubSub},
  {WebWidget,
   pubsub_server: MyHost.PubSub,
    authentication: [replica_nodes: [node()]]},
  {DynamicSupervisor, strategy: :one_for_one, name: MyHost.BridgeSupervisor},
  MyHostWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyHost.Supervisor)
```

Declare the same intended replica list on every distributed node, including the
local node; `[node()]` above is a single-node deployment example, not cluster
discovery. Multi-node deployments pass all intended node atoms. Environment
variable naming/parsing is entirely the host's choice. The endpoint can start
after infrastructure; readiness stays non-green until it is actually serving.

There is one infrastructure instance per BEAM node. Duplicate starts fail with
`{:already_started, pid}`. Init options are validated before children start and
invalid input returns `{:invalid_widget_configuration, field, explanation}`.
Configuration is immutable for that running instance, never copied into global
application environment. Replace infrastructure to change its options; existing
connector supervisors recover automatically using their retained host inputs.
Runtimes stop when their configuration owner stops, and
sessions/readiness are fenced by generation even before monitor delivery.
Keep the host connector supervisor outside the infrastructure restart domain
(for example, use `:one_for_one` above). Each `WebWidget.Connector` constructs a
fresh runtime after configuration-owner, registry, binding-store or whole
infrastructure replacement. The package handles bounded waiting/recovery; hosts
do not inspect private configuration or poll for recovery. To restart a standalone/demo composition
including its demo runtime, restart `WebWidget.Standalone`, not just one worker.
Local shutdown does not stop Mnesia or erase shared authentication state.

| Init option | Default / ownership |
| --- | --- |
| `pubsub_server` | Required host-owned response PubSub name; never started by infrastructure |
| `identity_verifier` | `:connector_key`, or a trusted verifier MFA |
| `authentication.token_ttl_seconds` | `604_800` |
| `authentication.refresh_lead_seconds` | `300`; must be less than token lifetime |
| `authentication.first_binding_window_seconds` | `5` |
| `authentication.control_proof_ttl_seconds` | `30` |
| `authentication.replica_nodes` | Required on distributed nodes; `[node()]` only when non-distributed |
| `transport.endpoint` | Unset; discovers the unique running widget endpoint matching the mount; explicit override disambiguates |
| `scope` | `"/"`; trusted mount scope; derives widget, control and asset paths |
| `transport.widget_path` | Derived `"/widget"` or `"<scope>/widget"`; legacy custom paths are root-only |
| `transport.scheme` | `:auto`; discovers a unique actual listener; `:http` / `:https` disambiguate dual listeners, not the public proxy scheme |
| `transport.tls_options` | `[]`; only verified `cacertfile` / `cacerts` |
| `proxy` | Disabled; optional unique exact `trusted_proxies` IP tuples and explicit root HTTPS `public_origin` |
| `session.partitioned` / `session.secure` | `true` / `false`; HTTPS always forces Secure |
| `session.endpoints` | `[]`; optional unique `{EndpointModule, [partitioned: boolean, secure: boolean]}` overrides |
| `public_url` / `token_url` | Optional public origin / authenticated same-origin token path |
| `response_diagnostics` | `false`; `true` or `:summary` opt in |

All authentication timings are positive integer seconds. Membership must be
nonempty, unique node atoms containing the local node. Startup configures no
host endpoint, TLS certificates, routes, connector, or listener. Cookie technical
policy and proxy trust are validated once and remain immutable for the generation.
Endpoint selectors only choose a process-owned policy; they never read widget
options from an endpoint.

### Migration from automatic startup

- Replace `start_web_server` / `start_integration_server` with explicit children.
- Move `config :web_widget, :authentication` into `authentication:` init options.
- Move trusted `:integration` values into init options; move nested `readiness:`
  and `widget_path` into `transport:`. Global settings no longer affect consumers.
- Replace preconstructed runtime specifications with supervised
  `{WebWidget.Connector, config: config, hooks: hooks}` children. Public builder
  construction callbacks are removed; generic hosts migrate to `HostAdapter`
  rather than constructing package children or translating raw status themselves.
- Update host capability checks to the connector lifecycle API rather than a
  builder construction callback. Validate readiness protocol version 2 and its
  verification scope; local ready must not be presented as externally verified HTTPS.
- Move endpoint `web_widget_session` to process `session:` and `web_widget_proxy`
  to process `proxy:` (with explicit public origin). Old endpoint widget options
  are ignored. Keep ordinary Phoenix endpoint URL, socket PubSub, listener
  addresses, TLS and signing secrets with its owner; no package-env copying.
- For the local demo use `mix demo`, which explicitly starts `WebWidget.Standalone`.
- Its optional raw mock runtime is temporary: an internal infrastructure-child
  crash drops that demo until the composition is restarted, rather than repeatedly
  restarting it against unavailable services. Real host connectors retain their
  independent package-owned recovery.
- For package-endpoint deployments explicitly supervise
  `{WebWidget.Standalone, mode: :package, infrastructure: widget_opts}`. This starts
  the package endpoint and local socket PubSub, but no Repo or demo. Serving
  endpoints are discovered even with partial transport options; use an explicit
  endpoint only to disambiguate. Response PubSub may reference the host server.
- Standalone without a mock runtime can explicitly supervise
  `{WebWidget.Standalone, infrastructure: widget_opts}`; development/test demos
  add `demo: [allowed_domains: [...], multiple_conversations: false]`.

### Routes and assets

#### Trusted scoped deployments

For a deployment below `/channels`, use the same trusted literal scope at
process startup and in all three compile-time macros:

```elixir
{:ok, specs} = WebWidget.HostAdapter.infrastructure_child_specs(
  pubsub_server: MyHost.PubSub, scope: "/channels")

# Host router, outside any extra Phoenix path scope and BO session pipeline:
import WebWidget.Router
web_widget("/widget", scope: "/channels")
web_widget_api("/widget-api", scope: "/channels")

# Host endpoint; leave the BO /live socket unchanged:
import WebWidget.Endpoint
web_widget_socket("/widget", scope: "/channels")
```

Public macro signatures are `web_widget(prefix \\ "/widget", opts \\ [])`,
`web_widget_api(prefix \\ "/widget-api", opts \\ [])`, and
`web_widget_socket(prefix \\ "/widget", opts \\ [])`; the only macro option is
`scope:`. Existing arity-1 calls are unchanged. Scoped calls accept the default
prefix or the exact fully-derived prefix (such as `/channels/widget`) without
doubling. A conflicting custom prefix or an additional outer Phoenix path scope
rejects compilation. Mount API controls outside the BO/browser session pipeline.

The scope creates `/channels/widget/:id`, its `/session` and `/live/*`,
`/channels/widget-api/:id/disconnect`, and `/channels/web_widget/assets/*`.
The reserved cookie remains HttpOnly/host-only with Path `/channels/widget/:id`;
old root cookies cannot verify or connect a scoped widget. BO cookies and `/live`
are unchanged. Layout script/CSS URLs, static serving and readiness probes use
the same derived paths; hosts do not copy assets or rewrite their URLs.

Omitting `scope:` or passing `"/"` preserves root mounting. A single trailing
slash normalizes away, for example `"/channels/"`. Scope accepts bounded absolute
paths of alphanumeric-leading segments with alphanumerics, `_` and `-`; empty,
non-string/relative values, repeated slashes, dot/traversal segments, percent
encoding, whitespace/backslashes, query and fragment are rejected with redacted
startup errors. Scope never comes from connector/browser settings or endpoint
policy. Runtime options cannot relocate Phoenix's compiled mounts: startup
rejects a proven explicit-endpoint mismatch; missing/inconsistent discovered
mounts cannot report green, and mismatched HTTP/session/socket/control requests
fail closed.
The supplied `WebWidgetWeb.Endpoint` is compiled for root mounting; passing a
scope to `Standalone` does not relocate it. Scoped hosts compile their own matched
endpoint/router mounts as above rather than starting a second package listener.

Legacy `transport: [widget_path: "/support/chat"]` remains valid at root. With
non-root scope, `widget_path` must be absent or exactly `/channels/widget`; even
the old `/widget` value conflicts. Do not silently combine custom paths and scope.

Online `WebWidget.HostAdapter.installation(config, base_url, [])` uses the running
scope. Offline trusted `installation(id, base_url, scope: "/channels")` derives
both loader and iframe URLs. Online overrides cannot contradict the installed
scope or widget path. Origins (`base_url`, `public_url`, proxy `public_origin`)
remain root HTTP(S) origins, not URLs containing a deployment path:

```html
<script src="https://HOST/channels/web_widget/assets/embed.js"
        data-widget-id="42" data-widget-url="https://HOST/channels/widget/42"
        defer></script>
```

The remaining examples below illustrate root/legacy mounts.

Add a released Git tag to the host's Mix dependencies and run `mix deps.get`:

```elixir
{:web_widget, git: "https://github.com/www-zaq-ai/web_widget.git", tag: "vX.Y.Z"}
```

Git dependency installs use the bundle committed in the tag; they do not fetch release attachments.

Mount the widget outside the host browser/authentication pipeline: the macro installs its own scoped session, LiveView flash, CSRF and secure headers. Do not fetch the BO session first. Backend controls remain separate and stateless; each request carries a strict signed backend proof.

```elixir
import WebWidget.Router

scope "/" do
  web_widget("/widget")
end

scope "/" do
  pipe_through :api
  web_widget_api("/widget-api")
end
```

Add the matching socket mount to the host endpoint, leaving BO's `/live` and session configuration unchanged:

```elixir
import WebWidget.Endpoint
web_widget_socket("/widget")
```

Each iframe uses only `/widget/:widget_id/live` (WebSocket or the existing long-poll fallback). Its HttpOnly, host-only `_web_widget_session` cookie has Path `/widget/:widget_id`, and uses package-specific signing options. Signed widget ID and mount path are verified at socket connection and connected page mount. Normal CSRF and socket origin checks remain enabled. Mount `web_widget` outside other authenticated `live_session` blocks; its macro creates its own. `allowed_domains` controls iframe parent origins separately.

`web_widget_socket/1,2` also wraps endpoint request handling to reject ambiguous
duplicates of the reserved cookie name before HTTP or socket parsing. Do not bypass
that wrapper in a custom endpoint `call/2`; delegate through `super/2`.
The rejection does not affect BO routes or unrelated duplicate cookie names.

Initial bootstrap may replace a single unusable/cross-widget cookie with fresh
anonymous CSRF state; it never carries over identity or conversation state.
Verification is read-only. Each iframe document initializes at most once, permits
at most three read-only resynchronizations, and allows ten seconds for bootstrap
plus LiveView establishment or each transient reconnect. Transport opens cannot
reset those limits. Failure shows an unavailable message and requires explicit
reload; identity renewal and authorized conversation restoration stay separate.
Backend revocation stops transport recovery without relabeling it as a session failure.

For a nested/custom router mount such as `/support/chat`, register `web_widget_socket("/support/chat")` on the endpoint and set infrastructure `transport: [widget_path: "/support/chat"]`. The returned `RuntimeBuilder.embed_script/2` snippet includes `data-widget-url="https://PUBLIC-ORIGIN/support/chat/42"`; the loader honors that URL and the iframe renders the corresponding socket URL. All three prefixes must match.

The `web_widget/1,2` macro serves `<scope>/web_widget/assets/*path` directly from the dependency's `priv/static/assets`, using `WebWidget.Static` as a route. Root deployments retain `/web_widget/assets/*path`. Released Git tags include the tracked production bundle. The host needs no Node installation, asset copy/build task, static-path allowlist entry, or endpoint static plug. Do not run a second package endpoint when mounting in the host endpoint.

The host-mounted topology uses the host endpoint for `/widget/:id`, `/widget/:id/live/*`, `/widget-api/:id/disconnect` and `/web_widget/assets`. A separate configuration-only package endpoint supports the same paths. Proxy the widget subtree, including WebSocket upgrades and long polling, to that endpoint; BO's `/live` must not be redirected. Keep one endpoint topology per public URL.

### Cookie policy and migration

Canonical connector `settings["same_site"]` must contain exactly `"None"`, `"Lax"`, or `"Strict"`. Missing, nil, blank and invalid values fail runtime construction. Directly registered runtime widgets must also supply `same_site`. New connector defaults belong to the host; endpoint policy fallbacks are not supported:

```elixir
%{settings: %{"same_site" => "Lax"}}
```

Populate every legacy connector's setting before upgrading, explicitly preserving its previous policy or selecting a new one. Partial edits must preserve that stored value. `WebWidget.Embedding.Session.effective(widget, endpoint, scheme)` resolves the widget policy, Secure flag and source, or a fixed configuration failure. It is not a transport readiness probe: #16 must verify host mounting before reporting a policy as applied; old/unverified adapters remain unknown. HTTPS forces Secure for every policy, including when partitioning is disabled and `secure: false` is configured. None requires HTTPS. HTTP development uses explicit Lax/Strict and does not silently downgrade None. Trust only correctly configured TLS termination/proxy scheme handling.

Widget transport cookies carry `Partitioned` by default for all SameSite policies.
Partitioning forces Secure and requires HTTPS, even if the host specifies `secure: false`.
This technical option belongs only to validated infrastructure options, not connector settings:

```elixir
# HTTP development only; retain normal Secure/SameSite rules when disabled.
{WebWidget, pubsub_server: MyHost.PubSub, session: [partitioned: false]}
```

Initial widget pages do not write cookies. Before connecting, each iframe uses
`<widget-page-path>/session` under a connector-path Web Lock, then performs a
read-only cookie acceptance check. Multiple instances share one transport cookie
within a top-level site; different parent sites use separate partitions. JWT/page
authorization and conversations remain independent. Blocked cookies fail explicitly.
Signed anonymous transport claims bind SameSite and technical Secure/Partitioned
policy. Old cookies lacking those technical claims, or cookies from a replaced
policy, must bootstrap fresh before connecting; the existing loader does this.

Install the package, endpoint mount, router pipeline, proxy rules and updated generated snippet together. Existing iframe documents using `/live` require reload; changing a connector policy requires runtime replacement and page reload. No BO cookie is rewritten by widget routes. Independently scoped widgets cannot overwrite one another's cookie attributes. Partitioned None supports cross-site embedding on supported browsers even when ordinary third-party cookies are blocked; Lax/Strict still do not support normal cross-site iframe sessions.

### Local readiness

Hosts invoke the configured adapter callback
`WebWidget.HostAdapter.ingress_status(config, timeout_ms: 2_000)` on the serving
node through its existing NodeRouter action. The serving endpoint and actual
listener are discovered automatically; configure overrides only to disambiguate:

```elixir
{WebWidget,
  pubsub_server: MyHost.PubSub,
  identity_verifier: :connector_key,
  transport: [endpoint: MyHostWeb.Endpoint, widget_path: "/widget", scheme: :https]}
```

In explicit package-endpoint composition, discovery selects `WebWidgetWeb.Endpoint`
when it is the sole matching endpoint. Scheme selects an **actual local listener**,
default `:auto`; choose `:http` or `:https` for dual listeners. Listener address/port come from the serving
endpoint, not a caller URL. Wildcard addresses are probed through loopback. The
endpoint's `url: [host: ...]` supplies Host, Origin and the verified TLS hostname;
normal socket origin checks stay enabled. Private CAs may be supplied through
`transport: [tls_options: [cacertfile: "/trusted/widget-ca.pem"]]` (or `cacerts`).
Disabling TLS verification is not supported. The probe uses Req for the cookie-free
page, `/session` initialization, and a read-only `/session?verify=1` round trip with
its anonymous cookie. It uses the verified JSON CSRF token, not the page meta token,
for the Mint (already used by Req) HTTP/1.1 WebSocket upgrade, then closes without
joining a LiveView or issuing/consuming identity credentials. All steps share the
original total deadline. No user cookie jar or browser coordination lock is used.

The adapter's closed channel status contains five checks, allowlisted effective settings and
`verification: %{scope: :local, session_handshake: :verified | :not_checked,
external_https: :not_checked}`. Internally it validates the raw version-2 observation;
see [adapter contract](adapter-contract.md#adapter-readiness-version-2). Cookie and
CSRF probe values, signing keys, callbacks, private configuration and raw failures
never leave the checker. Connector-key identity reports the installed connector
values. A custom verifier's opaque identity policy stays unresolved. Effective
SameSite is connector-owned. Direct-listener mode verifies the scoped bootstrap
cookie and socket; trusted-proxy mode reports configured enforcement, explicitly
marking the session handshake `:not_checked`. Endpoint inheritance is not supported. Partitioned,
Secure, HttpOnly, host-only and path attributes must match the installed policy;
neither the page nor the verification read may write a widget cookie. HTTP-only
development deployments must explicitly pass process `session: [partitioned: false]`.

Response-delivery checks cover the installed Phoenix PubSub registry, running
supervision tree and local PG2 membership, without subscribing or broadcasting.
Unsupported custom PubSub adapters report unknown rather than assumed readiness.
These checks do not establish availability of remote PubSub nodes.

Zero visitors can be ready. No new listener, connector endpoint process or browser
connection is introduced. Results are intentionally uncached: endpoint-wide listener
lookups are cheap; per-widget handshakes must reflect its current runtime/policy.
Runtime generation and listener identity are rechecked before a positive result.
Without authoritative lifecycle evidence the checker reports unavailable/unknown,
not a guessed starting state. Caller input accepts only a positive integer ID and
an optional 1–2,000 millisecond total timeout.

Readiness is local evidence, not proof that a public reverse proxy forwards widget
upgrades or that browsers accept third-party cookies. No cached external result is
reported. A public HTTPS URL alone never changes local scheme or cookie policy.

### HTTPS terminated by a trusted reverse proxy

Browser HTTPS/WSS -> trusted reverse proxy -> host HTTP/WS is supported without
a dedicated widget TLS listener. Configure the existing host endpoint:

```elixir
config :my_host, MyHostWeb.Endpoint,
  url: [scheme: "https", host: "chat.example", port: 443],
  http: [ip: {10, 0, 0, 2}, port: 4000],
  check_origin: ["https://chat.example"]

{:ok, infrastructure} = WebWidget.HostAdapter.infrastructure_child_specs(
  pubsub_server: MyHost.PubSub,
  proxy: [trusted_proxies: [{10, 0, 0, 1}], public_origin: "https://chat.example"])
```

The process-owned proxy policy supplies its explicit public origin; the endpoint's
normal URL remains host-owned. Proxy peer addresses are exact IPv4/IPv6 tuples,
not forwarded client addresses.
Keep the HTTP backend private. The TLS ingress must remove client-supplied
forwarding headers and overwrite `X-Forwarded-Proto: https`,
`X-Forwarded-Host: chat.example`. `X-Forwarded-Port` can be omitted for a configured
default-443 HTTPS origin, as with ngrok; the validated process authority supplies
443. If present, it must be a single exact matching port. Empty, duplicate,
comma-separated or conflicting values reject the request. Nondefault HTTPS
origins require an explicit matching port; no port is inferred from Host,
`X-Forwarded-For` or the private listener. Visitor addresses in `X-Forwarded-For`
do not establish immediate-peer trust. Forward cookies,
Origin, Upgrade and Connection correctly for `/widget/:id/live/*`, and route
widget pages, session endpoints and assets to the same host. Do not redirect BO
`/live` to a package listener. Malformed or mismatched trusted forwarding is
rejected; untrusted peer forwarding is stripped for widget requests.

`web_widget_socket/1` normalizes trusted scheme/host/port before both HTTP and
socket dispatch. Host/BO cookie handling remains untouched. Secure, HttpOnly,
Partitioned, SameSite, scoped cookie paths, CSRF and socket origin checks remain
enforced. Do not add another global forwarding rewrite that bypasses this trust
boundary for widget requests.

The package wrapper runs before the normal Phoenix endpoint plug pipeline,
including native `force_ssl: [rewrite_on: [:x_forwarded_proto]]`. Malformed trusted
forwarding rejects even when `conn.scheme` is already HTTPS. If an external
middleware runs before that wrapper, it must enforce the same immediate-peer
allowlist before rewriting: removing an untrusted header later cannot recover the
original transport scheme. Restrict the backend to trusted ingress. This does not
authorize blanket scheme rewriting or using visitor `X-Forwarded-For` as trust.
This peer filter requires the explicit process `proxy:` block. If it is omitted,
the package does not validate host-wide SSL rewriting; native `force_ssl` alone
does not establish widget proxy trust. Keep such a backend restricted to ingress.

Local readiness verifies the actual HTTP listener, mounted widget socket, rejection
of insecure page/session requests (503 or a redirect to the exact public HTTPS
origin/path) and the configured HTTPS cookie policy. It sends
no forged forwarding headers and marks `session_handshake: :not_checked` and
`external_https: :not_checked`. A local ready result remains possible if the public
proxy is down; external deployment verification must independently exercise real
HTTPS page/bootstrap/cookie verification and WSS upgrade through that proxy.
Keep browser cross-site connect/reconnect checks alongside that verification.

## Runtime builder and shared protocol

The resolved connector must include string-keyed settings
`%{"identity_issuer" => "zaq_issuer", "identity_audience" => "zaq_audience"}`.
ZAQ supplies these new-connector defaults; sign tokens with the actual configured
values. Identifiers must be exact UTF-8 strings of 1–255 bytes without surrounding
whitespace. Missing or invalid settings fail construction; integration options
provide no fallback. Upgrade existing connectors atomically before installing this
version. Editing either identifier requires host connector replacement, invalidates
old sessions and rejects tokens with old claims.

Use `WebWidget.HostAdapter` for generic adapter callbacks; `RuntimeBuilder`
status/installation functions remain deliberate raw-package compatibility APIs.
The host's existing supervisor owns connector creation, replacement and removal.
One enabled connector corresponds to one `WebWidget.Connector` subtree and a
positive integer connector ID. The string form is the public widget route ID.
Runtime construction reads the host's resolved connector key privately; no key
appears in public widget configuration or the installation snippet.

```elixir
{WebWidget,
  pubsub_server: MyHost.PubSub,
  identity_verifier: :connector_key,
  token_url: "/api/widget-token"}
```

The package also accepts a trusted custom verifier MFA for browser identity, but the signed backend disconnect route is available only with connector-key verification. The verifier receives `(proof, %{widget_id: string_id, channel_config_id: integer_id, page_id: signed_socket_id})` after any configured prefix arguments and returns `{:ok, %{sender_id: external_id, expires_at: unix_seconds}}` or an error. Conversation and prompt metadata are supplied later through `zaq.widget.updateContext`, never through JWT identity or verifier output.

```elixir
{:ok, connector_pid} = DynamicSupervisor.start_child(
  MyHost.BridgeSupervisor,
  {WebWidget.Connector, config: resolved_connector, hooks: host_hooks}
)

# Replacement: terminate the old subtree, then start with updated host inputs.
:ok = DynamicSupervisor.terminate_child(MyHost.BridgeSupervisor, connector_pid)
```

Configuration contains `id`, `provider: :web_widget` (or `"web_widget"`), private
`token` and canonical string-keyed settings. Identity identifiers and SameSite
are mandatory even with a verifier override. `display_name` and `allowed_domains`
may be supplied on config (taking precedence) or trusted presentation hooks.
Hooks contain the matching `widget_id` plus `message`, `command`, `context`,
`delivery`, `response`, and config-bound `sink_mfa` constructors. Invalid inputs
fail before startup with a fixed redacted error. Valid inputs may wait for absent
infrastructure. Duplicate IDs fail even during recovery; child-spec IDs alone do
not enforce uniqueness in DynamicSupervisor.

The child specification contains redacted-inspection wrappers around server-only
host inputs. Package diagnostics redact secrets, but privileged VM debugging
(`:sys.get_state`, tracing) is not a security boundary. Hosts must likewise avoid
logging raw config/hooks. Recovery is monitored and uses capped timer backoff,
not supervisor restart loops. Removal shuts down all recovery work; infrastructure
retains no connector configuration and cannot recreate a removed connector.

The package calls `sink_mfa` in the caller with a constructed payload and
server-owned context. The host routes messages, authorizes resume/history,
persists conversation state, and publishes `{:web_response, adapter_event_name,
shared_response}` to the private delivery topic. The package subscribes before
the first question, checks request/conversation/message correlation, and forwards
public `response.*` events to React. No second browser WebSocket, SSE, AG-UI, or
compile-time host dependency is needed.

For an integrated connector, the installer emits a public script containing the widget ID and the optional `token_url` attribute from integration configuration. The embedding website supplies that authenticated same-origin endpoint and may use:

```html
<script src="https://ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="42" data-widget-url="https://ZAQ-HOST/widget/42"
        data-token-url="/api/widget-token" defer></script>
```

`iframe-location-id="#my-widget-container"` selects an existing div with a parent-supplied height. If that div is `#zaq-widget`, the iframe ID is `#zaq-widget-frame`; otherwise it is `#zaq-widget`. `stylesheet-url` is a parent-supplied HTTP(S) CSS URL, handled by the validated postMessage handshake. Neither stylesheet nor presentation settings belong in JWT identity. See [styling](styling-guideline.md) and the [website guide](integration-guideline.md).

## Authentication state and deployment

Set infrastructure `authentication:` init options with a seven-day `token_ttl_seconds` (or another value longer than renewal lead), five-second `first_binding_window_seconds`, five-minute `refresh_lead_seconds`, 30-second `control_proof_ttl_seconds`, and explicit `replica_nodes`. Each configured node must agree on membership. The package uses replicated majority-protected Mnesia RAM tables for page bindings, control idempotency, user revocation cutoffs, and reset metadata. A minority fails closed. A restart rejoins surviving state; complete RAM loss establishes a new cutoff only at quorum. No host SQL migration is needed. Tokens issued in the reset/cutoff second may need retry in the next second.

The initial JWT is bound to the signed Phoenix `socket.id` before conversation initialization. Subsequent checks gate dispatch and response application. In-place renewal preserves the same sender, widget, page, subscription, active stream, draft, and settings. A normal LiveView reconnect uses the same bound token. A full iframe reload needs a new token. The parent client fetches fresh tokens and schedules renewal from server metadata. On store unavailability it waits for authority to recover; backend disconnect is terminal for that iframe.

`web_widget_api("/widget-api")` mounts `POST /widget-api/:widget_id/disconnect`. The backend sends JSON `{"user_id":"..."}` and `Authorization: Bearer <control JWT>`. The JWT has strict `iss`, `aud: identity_audience <> ":control"`, `op: "disconnect"`, numeric `widget_id`, `user_id`, integer `iat`/`exp`, and random `jti`; validity is at most 30 seconds. The request nonce is idempotent in Mnesia. The cutoff commits before a scoped PubSub broadcast; matching LiveViews unsubscribe, notify their parent, display the refresh message, and close transport. A browser JWT cannot authorize this operation. See [authenticated chat](authenticated-chat.md) for issuance examples.

Exact allowed HTTP(S) parent origins determine the CSP `frame-ancestors` policy and parent postMessage acceptance. Missing or empty origins deny embedding, including same-origin. Missing/stopped runtimes render an unavailable view. Connector replacement invalidates previous runtime sessions; new mounts resolve the current runtime.

## Build and release assets

Dependency configuration files are not imported by Phoenix. Starting the OTP
dependency starts no widget services. Explicitly supervise the infrastructure
child as described above; do not enable legacy startup flags.
Widget rendering explicitly disables React SSR; no Node SSR service
or global LiveReact setting is needed.

Release Please opens a version and changelog PR from conventional commits. Merging
it creates the `vX.Y.Z` tag and GitHub Release and updates the Mix project version.
GitHub Actions installs JavaScript dependencies with `npm ci`, runs the existing
Vite build, checks that all compiled files match the tracked bundle, and attaches
the bundle archive to the release. The assets must be committed with frontend
changes, since Git dependencies receive the tag contents rather than attachments.
When assembling a host release, retain the dependency's `priv/static/assets`
directory. Static responses revalidate with ETags.

Embed `/widget/<connector-id>` on a configured allowed origin. The existing
[website examples](../README.md#add-the-widget-to-your-website) demonstrate the
embed script, readiness, settings and resizing. The
[signed bootstrap guide](authenticated-chat.md) covers backend proof issuance
and the configuration needed before real ZAQ use.

## Verification

Run `mix assets.build`, `mix test`, and `mix precommit` in this repository. Run Chromium Playwright tests in `assets/` with the installed browser. The package also provides `test/support/integration/shared_protocol_smoke.exs` for the pinned sibling ZAQ constructor contract and host mounted asset smoke scripts under `test/support/integration/`. These checks do not call a live agent/model; a final deployment smoke should exercise its real token endpoint, first question, authorized resume, renewal, and backend disconnect.

Run `npm --prefix assets run test:e2e` for the complete root-mount browser suite,
then `npm --prefix assets run test:e2e -- --config=playwright.scope.config.ts`
for the separate scoped singleton with real proxy TLS/WSS, generated installation,
bundled assets, authentication/assistant delivery, cookie isolation and signed
disconnect. The two fixtures use the same ports and must not run concurrently.
