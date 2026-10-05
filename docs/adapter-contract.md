# Web Widget Adapter Contract

## Status and source of truth

Decision recorded in wiring milestone 0, 2026-10-05. This document defines the
selected ZAQ integration against shared web protocol **version 1** at
[`c38e7e4e5`](https://github.com/www-zaq-ai/zaq/blob/c38e7e4e5/docs/services/web-bridge.md).
ZAQ's [installation handoff](https://github.com/www-zaq-ai/zaq/blob/c38e7e4e5/docs/guides/web-widget-integration.md)
and published constructors own the host protocol. This document owns the widget's
integration decisions and presentation mapping, not a second shared schema.

The package now implements the milestone 1 runtime builder and server-side
session/ingress boundary. LiveView still uses the plain-map mock callback, eager
conversation initialization and conversation-topic delivery; those remain
migration gaps, summarized under [implemented delivery boundary](#implemented-delivery-boundary).
The [wiring plan](exec-plans/wiring-widget.md) tracks implementation and acceptance.
Do not infer deployed support from the target contract below.

## Responsibilities and boundary

`web_widget` owns iframe delivery, parent postMessage validation, server-side
verification of parent identity/session, subscription authorization, LiveView
browser state and assistant-ui presentation. It translates widget actions using
host-supplied constructors and encodes public responses for its UI.

ZAQ owns connector configuration and lifecycle, People identity resolution,
conversation ownership and durable history, permissions, routing, agent selection,
and shared Message/Command admission through WebBridge and existing role dispatch.
The widget does not call Engine or construct Incoming/Outgoing directly.

ZAQ depends on `web_widget`; the package has no compile-time dependency on ZAQ
internals. Constructor inputs and UI events are plain maps. Host-supplied
constructors produce shared boundary values consumed through trusted runtime
hooks, without `%Zaq.*{}` struct literals in the package. ZAQ never constructs
`WebWidget.*` structs. This replaces the earlier plain-map-only callback decision.

## Runtime integration

Use the existing channel lifecycle and BridgeSupervisor. The provider entry in
ZAQ's existing Channels map is:

```elixir
web_widget: %{
  bridge: Zaq.Channels.WebBridge,
  runtime_builder: WebWidget.Integration.RuntimeBuilder
}
```

`WebWidget.Integration.RuntimeBuilder.build(config, hooks)` returns
`{:ok, {state_child_spec_or_nil, listener_specs}}` or `{:error, reason}`.
It reuses the package runtime registry. ZAQ owns startup, rollback, restart and
teardown lifecycle; do not independently start a duplicate runtime. The local
ZAQ installation now selects this builder through configuration and a path
dependency; no ZAQ module or test changes are needed for runtime startup.

Hooks supply `widget_id = config.id`, presentation settings, the shared
`message`, `command`, `context`, `delivery`, `response` modules, and the
config-bound `sink_mfa`. They do **not** supply a PubSub server. For this host,
the adapter receives `Zaq.PubSub` through trusted application configuration.
`config :web_widget, :integration` supplies `pubsub_server` and `identity_verifier`
(an MFA); `build/3` accepts these options explicitly for isolated consumers/tests.

One persisted connector identifies one widget. Keep its positive integer ID in
Context/Delivery and use its string form in the registry and `/widget/:widget_id`.
Do not persist a separate `widget_id` setting. Host settings are `display_name`,
`allowed_domains` (exact HTTP(S) origins). Stylesheets are not connector settings
or runtime hooks. The host shared command supports validated stylesheet params,
but this adapter no longer accepts them through browser initialization. A future
stylesheet bootstrap field must first be added to the signed schema.
Theme and language remain parent-owned. Start with `multiple_conversations: false`;
ZAQ v1 does not provide the current widget's eager conversation-list contract.

The local ZAQ install now mounts the package router/static plug on its existing
endpoint, as explicitly requested by the user after milestone 1a. Its `/live`
socket serves the iframe; BO authentication does not apply to the widget mount.
This supersedes the earlier configuration-only choice for this installation.

For hosts retaining configuration-only installation, opt in to
`start_integration_server: true` to start the package endpoint and its socket
PubSub once, without the Repo/demo. Connector runtimes remain ZAQ-owned and use
`Zaq.PubSub` for responses. The iframe uses this endpoint's existing `/live`
connection; no additional browser realtime connection is introduced.

`RuntimeBuilder.embed_script(widget_id, base_url)` returns one escaped script tag
with `data-widget-id`. The optional trusted integration `public_url` overrides
the supplied base URL; otherwise the deployment must proxy `/widget`,
`/web_widget/assets` and `/live` at the ZAQ base origin to the package endpoint.
Only root HTTP(S) origins are supported. The loader creates a single iframe at
`/widget/<id>` on its own origin and applies the existing layout/client behavior.
It never invents identity or embeds credentials. Manual iframe initialization
remains supported. See [host integration](host-integration.md).

## Identity, embedding and parent bootstrap

JWT decision: signed initialization uses compact JWT with HS256 only, verified
by JOSE with an explicit algorithm allowlist. The HMAC key is the exact UTF-8
connector key shown by ZAQ BO, without Base64 decoding or salt. Header `typ` is
`JWT`. Required claims are `widget_id` (positive integer), `user_id`, nullable
`conversation_id` and `prompt_context`, `iss`, `aud`, integer Unix-second `iat`
and `exp`, and random `jti` (16–255 characters). Lifetime is at most 300 seconds;
future issuance/expiry violations fail closed. Optional `nbf` is enforced.
Unknown claims/header extensions and non-HS256 algorithms are rejected. Existing
Phoenix.Token proofs are not accepted. Issuer/audience/replay/session revocation
rules remain unchanged.

Updated initialization decision: the authenticated browser API accepts only
`init({identity_token})`. The signed token contains `user_id`, `conversation_id`
and `prompt_context` (the latter two may be nil), alongside widget scope,
issuer/audience, expiry and nonce. The server derives all initialization context
from verified claims; unsigned overrides, settings, params and unknown fields
are rejected. Every future initialization field must be added to the signed
claim schema and validator. Settings are excluded from init and changed only
through the separate settings API. Per-instance stylesheet initialization is
withdrawn until explicitly added to the signed schema. Standalone mock fixtures
retain their three-field test bootstrap, without settings or params; they cannot
initialize an integrated ZAQ runtime.

Milestone 2 implementation decision: opt in with `identity_verifier: :connector_key`.
The builder binds the resolved connector token privately to `SignedIdentity`.
Proofs use HS256 JWT with a five-minute maximum lifetime, explicit
issuer/audience, widget, sender, issue/expiry times and random token ID.
`SignedIdentity.sign/4` runs only in the parent backend. The browser sends the
result as `identity_token`; verified `user_id` becomes the internal sender identity.
Nonce consumption is atomic and node-local, survives connector replacement, and
permits reuse only by the same LiveView process. A new LiveView/reload therefore
requires a fresh proof. Deploy a single widget node until a shared replay store is
configured/implemented. Never put the connector key in browser code.
Runtime monitoring and expiry timers revoke subscriptions and prevent late delivery.
Standalone legacy demo fixtures remain isolated from integrated runtimes; shared
protocol fixtures exercise the production LiveView path without ZAQ dependencies.

An allowed origin and a nonblank browser `user_id` do not authenticate a sender.
The adapter must verify parent-app identity/session server-side before constructing
Context, accepting protected operations or subscribing. Keep only the verified
external sender, scope and expiry in trusted session state. It is not a ZAQ Person
ID or People bearer. ZAQ separately authorizes the sender against connector and
conversation ownership on every operation.

The parent owns its authenticated session and supplies proof through the widget
bootstrap through `init({identity_token})`; no `init({user_id})` example alone
establishes this security property. Signing/key enrollment
is host configuration, not a shared `widget.authenticate` command. Never retain
credentials in prompt context, history or canonical routing metadata.

The implemented server entry point is `Runtime.authenticate(widget_id, proof)`.
The configured verifier receives `args ++ [proof, scope]`, where scope contains
the string widget ID and integer channel configuration ID. It must verify proof
against that scope and return `{:ok, %{sender_id: external_id, expires_at: unix_seconds,
init: %{user_id: external_id, conversation_id: id_or_nil, prompt_context: text_or_nil}}}`.
For custom identity-only verifiers, omitted `init` defaults to the verified sender
and nil optional fields; no browser data can fill them. To support resume/context,
custom verifiers must validate and return those signed claims.
Missing/invalid/expired verification fails closed. The package retains no proof.
The resulting server-only Session is bound to the calling process and current
runtime generation. Never construct it from browser maps. `Runtime.dispatch/2`
and `Runtime.subscribe/1` reject expired, foreign-process and replaced-runtime
sessions. The shared Chat/LiveView path monitors runtime replacement, schedules
expiry and unsubscribes on revocation; standalone callers own cleanup.

Both sides check postMessage source and exact origin. Use the iframe origin as
`targetOrigin`. The ready/ready-request handshake means the hook is listening,
not that the sender is authenticated. Reject missing, expired or foreign proof;
reject claimed-user disagreement and browser-selected topics/configuration IDs.
Reverify on reconnect, enforce expiry while connected and remove subscriptions
when authorization ends. Renewal must not silently change the session's sender.

`allowed_domains` denies embedding when absent/empty, including same-origin
embedding. Enforce CSP `frame-ancestors` and the parent source/origin checks; remove
conflicting X-Frame-Options only on the widget route. Preserve other CSP directives.
HTTP framing policy changes require iframe reload. Runtime/identity revocation
must also block existing sessions from new sends/history/response delivery.

Verified token claims include `user_id`, `conversation_id` and `prompt_context`.
Validate their raw values before calling shared constructors:
invalid optional identifiers can normalize to nil. Reject malformed supplied IDs
rather than silently treating them as a new conversation. Parent context is ordinary
user input, never permission, agent selection or privileged prompting.

## Inbound communication: web_widget -> ZAQ

Use the host constructor modules supplied in trusted hooks. Unknown wire events
and all inbound `message.edit` requests are rejected. Widget actions map as follows:

| Widget action | Shared operation |
| --- | --- |
| `widget.init` | Command `:conversation_init`, with request ID and optional validated resume ID |
| `conversation.history.request` | Command `:conversation_history`, with request ID, conversation ID and bounded history params |
| `message.create` | Message with request ID, message ID, UTC `DateTime`, content, channel, mode, optional conversation ID and first-question parent context |

The adapter chooses mode; the initial integration uses async questions. Channel
is a routing selector, not authority to select an internal agent. Do not send
capabilities, supplied history, actors, internal IDs or dispatch choices in messages.
Shared constructors validate the definitive fields and constraints.

Build Delivery for `consumer: :widget`, trusted integer configuration ID and an
authorized session topic, with all seven mappings:

```elixir
%{
  typing: "response.typing",
  message_create: "response.message.create",
  message_edit: "response.message.edit",
  message_step: "response.message.step",
  message_complete: "response.message.complete",
  message_failed: "response.message.failed",
  error: "response.error"
}
```

Build Context with nil actor, `consumer: :widget`, verified `sender_id`, integer
`channel_config_id` and Delivery. Nil actor grants no capability. Do not supply
BO bypasses, agent selection, history or content-filter overrides.

Invoke the published config-bound sink with its argument prefix:

```elixir
{module, function, args} = hooks.sink_mfa
apply(module, function, args ++ [payload, [context: verified_context]])
```

`sink_mfa` is an in-process callback, not a transport. Browser input cannot replace
it, its bound config, constructor modules or Context.

## Sync vs async events

| Operation | Sink result |
| --- | --- |
| Command | Semantic Response directly, including semantic `:error` on command failure |
| Async message accepted | `{:ok, Response}` creation/status receipt; terminal comes later |
| Sync message | One terminal Response directly; no duplicate live terminal |
| Failure before acceptance | May return `{:error, reason}` |

Do not wrap all responses as `{:ok, map}` or reduce accepted receipts to `:ok`.
Distinguish valid semantic errors from success. Keep request, conversation and
message correlation through result handling and UI encoding.

## Widget initialization

Opening a widget creates no chat or history. A fresh init returns
`:widget_initialized`, `created: false`, and no new conversation ID. Authorized
resume returns the existing ID; unknown, foreign, deleted or unbound IDs fail
without replacement creation.

The first-question sequence is:

```text
verify parent session -> readiness (conversation_id nil)
  -> subscribe to authorized session destination
  -> submit first async question with retained optional prompt_context
  <- accepted conversation_created receipt with new conversation ID
  <- live typing / assistant events on the pre-existing subscription
```

Retain parent context until the first actual Message. ZAQ persists it as ordinary
user history when creating that conversation. Resume/later questions do not reseed.
An accepted resumed question returns `:status`, `accepted: true`, `created: false`.

Only a matching receipt establishes a new active conversation. Wait for its ID
before another submission and preserve the active-response guard. Live events
may queue before the callback returns; process them only after acceptance is
bound. If dispatch moves to another process, explicitly buffer this race.

## Outbound communication: ZAQ -> web_widget

Subscribe on the configured host PubSub server before the first question using
a server-generated unpredictable destination authorized for the verified iframe
session. It must exist without a conversation ID. Keep it stable for that session;
reconnect creates/reestablishes an authorized subscription after verification.

ZAQ publishes `{:web_response, adapter_event_name, shared_response}`. Consume that
single ingress and encode once into widget UI events; do not republish into the
old broad conversation topic. ZAQ keeps no LiveView PID. Its RequestOwner's internal
reply topic is separate from the adapter session destination.

Check protocol version, trusted event mapping, request ID, accepted conversation
and transport message ID before applying events. Widget ID and sender come from
the session. Reject stale/foreign responses; unsolicited events cannot switch
conversations. UI output retains the `response.*` namespace.

## Outbound payloads

Shared Response uses semantic `type`, `protocol_version: 1`, `request_id`, optional
`conversation_id`/`message_id` and public `payload`. Map this into the existing UI
vocabulary while preserving correlation; do not make ZAQ emit widget-private maps.

| Shared semantic type | Widget encoding / handling |
| --- | --- |
| `:widget_initialized` | `response.widget.initialized`; readiness with optional ID; displayed user comes from verified session |
| `:conversation_created` | `response.conversation.created`; direct correlated receipt establishes the conversation |
| `:conversation_history` | `response.conversation.history`; ordered public messages and separately retained pagination positions |
| `:status` with accepted true | Direct resumed receipt, not assistant text or a terminal |
| `:typing` | `response.typing`, boolean `active` |
| `:message_create`, `:message_edit`, `:message_complete` | Corresponding `response.message.*`; top-level transport `message_id` becomes UI payload `id`, public `body` becomes `content` |
| `:message_step` | `response.message.step`; public `step_id` and message ID, safe label; `:activity/:running` maps to `status/started` or `updated` for an existing step |
| `:message_failed` | `response.message.failed`; correlated message ID, known public code/error mapped to safe UI code/text |
| `:error` | `response.error`; correlated request and safe code/text; retain timeout `outcome: :unknown` |

Streaming edits replace the full content snapshot; never append as token deltas.
Status and reasoning steps use only transient progress presentation, not persistent
activity cards. Only explicit `tool_call` and `tool_result` steps appear in the
activity panel and its counts; generic activity labels never imply tool execution.
The assistant transport ID is stable across create/edit/step/terminal and may differ
from persisted assistant/user message references. Retain those references separately.
Never expose BO traces, private reasoning, raw tool calls or agent metadata.

Live ordering is typing active -> assistant create -> optional edits/steps -> typing
inactive -> one correlated terminal. A create precedes subsequent assistant events.
Update steps by step ID; terminal message/step states cannot regress. Ignore duplicate
or late terminals and typing resets from earlier requests.

## Conversation ownership and history

ZAQ owns durable history; LiveView owns current browser state. Do not send complete
history with each question. Resume must verify identity, authorize the selected ID
and load history before accepting another send. Full page reload restoration requires
an explicit parent resume mechanism retaining the accepted ID; browser identity alone
or prior LiveView memory does not guarantee restoration.

Shared history params are `limit` (default 50, maximum 100), `after_position` and
`up_to_position`. Preserve returned positions for bounded pagination, distinct from
conversation/transcript identifiers. Render oldest to newest, normalizing public IDs,
roles and timestamps. Never invent timestamps for untimestamped history. Preserve
message creation times during streaming; format dates in the selected language and
browser time zone.

PubSub offers no durable replay or exactly-once execution. Timeout is an unknown
outcome, not cancellation or permission to retry. Accepted work can finish later.
Recover through authorized history when the conversation ID is known. If an initial
timeout returns no ID, surface unresolved outcome rather than inventing an ID or
silently resending. Consult the host contract for timeout bounds.

Multiple-conversation listing/sidebar integration is deferred. The existing mock's
`include_conversations` response is not part of the shared ZAQ v1 history command.

## Parent-owned presentation settings


Theme and language are not persisted ZAQ widget configuration. Each iframe starts
with `%{theme: "auto", language: "en"}`. Its allowed parent sends
`zaq.widget.settings.update` separately from init, or optionally inspects current
values with `zaq.widget.settings.get`. Settings in init are rejected.
Supported values: theme `auto/light/dark`, language `en/fr/ar`. Unknown keys and
invalid values reject the entire update. Settings cannot change identity, routing,
origins, stylesheet URLs, or conversation ownership. Init never changes settings;
repeated init does not rewind runtime preferences.

Requests may carry `request_id`; the iframe replies to the validated parent origin
with `zaq.widget.result`, the same ID, and either `ok: true, settings: {...}` after
application or `ok: false, error: "..."`. Both sides verify source and exact origin.
The parent client uses these messages and a timeout; it owns no conversation state.
Settings survive LiveView reconnects in the same iframe document. Reloading the
iframe resets its defaults; the parent client reapplies its latest preferences.

Gettext supplies UI strings and plural summaries, and the browser formats dates
in the selected language and local time zone. Arabic switches the document to RTL.
Host content remains unchanged. Runtime updates preserve drafts, messages, pending
responses, and selected conversations. Custom CSS may override color tokens but
there is no theme-selection CSS variable. ZAQ owns its response language.

The parent may load `/web_widget/assets/embed.js` to expose `zaq.widget` for a
single `#zaq-widget` iframe. This wrapper owns outer iframe defaults, validated
resize handling, and parent scroll locking; it delegates identity and settings
to the existing client. It requires explicit `init({user_id})` and generates no
identity. The lower-level module remains available for independent widget instances.
An allowed parent can send `zaq.widget.ready.request`; a ready hook replies with
`zaq.widget.ready`. This handshake supports clients attaching after iframe load
without navigating the iframe again. Source and origin checks apply to the probe.


The current explicit `init({user_id})` API above describes presentation/bootstrap
behavior, not sufficient identity proof for ZAQ v1. Verified bootstrap preserves
the settings ownership boundary. Browser initialization no longer accepts stylesheet
params. Standalone runtime stylesheets and the bundled defaults remain available.

## Implemented delivery boundary

This section records migration evidence, **not another supported ZAQ contract**.
At package revision `a134225f3f059768be6742cc92acfd1192e1fce7`:

- `Runtime.dispatch/1` calls `apply(module, function, [event | args])` and its mock
  returns `{:ok, response_map}` for init/history or `:ok` for accepted messages.
- `Events` and `Response.normalize/1` require a nonblank conversation ID before
  message delivery; initialization supplies that ID eagerly.
- `Adapter.send_event/1` publishes `{:web_widget_response, event}` on an encoded
  widget/conversation topic; WidgetLive subscribes after initialization.
- Bootstrap checks ID shape, origin and source, but does not verify identity proof.
  Mounted views are not automatically revoked by runtime changes.
- Mock history is fixture data; multi-conversation UI and callbacks do not prove
  canonical persistence, authorization or the shared ZAQ lifecycle.

Milestone 1 adds `Integration.RuntimeBuilder`, `Integration.Protocol` and
`Integration.Session` while preserving public configuration lookup. The old
`Runtime.dispatch/1` rejects integrated runtimes with `:authentication_required`;
authenticated callers use `Runtime.dispatch(event, session)`. The new internal
event maps carry the operation/request fields only, not `widget_id` or `user_id`:
the session supplies trusted identity/scope. Unknown fields/events and message
editing are rejected. Raw resume IDs are checked before shared construction.
Responses retain the host's return shapes; UI encoding is milestone 2.

Milestone 2 adds `Integration.Chat` and semantic `Integration.Response` encoding.
Integrated runtimes use only the verified shared path in WidgetLive. A shared host
fixture and browser smoke exercise that path, including responses queued before
acceptance. Legacy standalone demo callbacks remain supported for existing
consumers, but cannot dispatch to integrated runtimes. See
[authenticated chat](authenticated-chat.md) for configuration and current
single-node replay/50-message history limits.
