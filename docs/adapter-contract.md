# Web Widget Adapter Contract

This document defines how the `web_widget` Phoenix dependency integrates with ZAQ as a communication channel.

## Purpose

`web_widget` owns:

- iframe / LiveView delivery
- React + `live_react` + assistant-ui presentation
- browser-side widget lifecycle
- parent-page `postMessage` integration
- publishing widget events to ZAQ
- receiving ZAQ response events and delivering them to the correct `WidgetLive`

ZAQ owns:

- channel configuration
- widget runtime startup
- identity resolution / validation
- conversation persistence
- routing and agent selection
- permissions
- translating widget events into ZAQ `Incoming`
- producing response events

The boundary between ZAQ and `web_widget` should use plain maps. Do not require ZAQ to construct `WebWidget.*` structs.

---

## Runtime integration

`web_widget` is a dependency of ZAQ and runs inside the same BEAM application.

ZAQ should expose the widget LiveView route through the host router, for example:

```elixir
import WebWidget.Router

web_widget("/widget")
```

The iframe can then use:

```text
/widget/:widget_id
```

The widget reuses ZAQ's Phoenix endpoint and LiveView socket. It does not start a second HTTP server or a separate browser WebSocket.

### Channel configuration

Conceptually:

```elixir
config :zaq, :channels, %{
  web: %{
    bridge: Zaq.Channels.WebBridge,
    adapter: WebWidget.Adapter,
    sink_mfa: {Zaq.Channels.WebBridge, :from_listener, []}
  }
}
```

`sink_mfa` is an in-process callback destination. It is not a WebSocket configuration.

The LiveView WebSocket is owned by Phoenix / LiveView.

---

## Runtime configuration handoff

When the Web Widget channel is enabled, ZAQ should use the existing channel runtime lifecycle:

```text
ChannelConfig
  -> CommunicationBridge / Bridge lifecycle
  -> WebBridge.build_runtime_specs/1
  -> ChannelSupervisor
  -> WebWidget runtime
```

`WebBridge.build_runtime_specs/1` should pass the widget runtime only the fields it needs.

Example:

```elixir
%{
  channel_config_id: 42,
  pubsub_server: Zaq.PubSub,
  sink_mfa: {Zaq.Channels.WebBridge, :from_listener, []},
  widgets: [
    %{
      widget_id: "widget_support",
      display_name: "Support Assistant",
      allowed_domains: [
        "https://customer.com"
      ],
      stylesheet_url: "https://customer.com/widget.css"
    }
  ]
}
```

### Parent-owned presentation settings

Theme and language are not persisted ZAQ widget configuration. Each iframe starts
with `%{theme: "auto", language: "en"}`. Its allowed parent may include a partial
`settings` object in `zaq.widget.init`, then send `zaq.widget.settings.update` at
any time or optionally inspect current values with `zaq.widget.settings.get`.
Supported values: theme `auto/light/dark`, language `en/fr/ar`. Unknown keys and
invalid values reject the entire update. Settings cannot change identity, routing,
origins, stylesheet URLs, or conversation ownership. Startup settings apply only
on the first accepted context; repeated init does not rewind runtime preferences.

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

### IDs

`widget_id` and `channel_config_id` are separate.

One ZAQ channel configuration may own multiple widgets:

```text
channel_config_id = 42
  -> widget_support
  -> widget_sales
```

Each widget may have different:

- allowed origins
- display name
- stylesheet
- other UI configuration

Routing / agent selection remains owned by ZAQ.

---

## Parent-page bootstrap

The parent page communicates with the iframe through `window.postMessage`.

On initial iframe bootstrap, the parent provides:

- `user_id`
- optional `prompt_context`
- optional `conversation_id` (`nil` for a new conversation)

The iframe announces `{type: "zaq.widget.ready"}` once its LiveView hook is
listening, and again after reconnecting. The parent replies with
`{type: "zaq.widget.init", user_id, prompt_context, conversation_id}` using the
iframe's exact origin as `targetOrigin`. A load event alone is too early to
guarantee that LiveView is listening.

The `/widget/:widget_id` route denies embedding by default. ZAQ must provide
`allowed_domains` for each widget: exact HTTP(S) origins (scheme, hostname, and
port), without paths, queries, credentials, fragments, or wildcards. A trailing
slash is accepted and normalized. Missing, null, or empty lists disable the
widget; malformed entries reject runtime configuration. There is no implicit
same-origin allowance. The HTTP response enforces the list using CSP
`frame-ancestors` (or `'none'` for unavailable widgets), preserving other CSP
directives. The widget route removes the default `X-Frame-Options` header so
explicitly allowed cross-origin parents can embed it.

The browser checks both the parent window and its configured origin. LiveView validates the
payload and retains only these three fields as untrusted bootstrap context.
`user_id` must be a nonblank string; `conversation_id` may be a nonblank string
or null; `prompt_context` may be a string or null. Omitted optional
fields become null. The chat UI stays unmounted and submissions are rejected
until valid context with a nonblank `user_id` is received. Invalid bootstrap
messages produce a developer console error with postMessage instructions; if
no valid context arrives within five seconds of readiness, the same guidance
is logged. A later valid message can still initialize the widget.
Identical retries are accepted; replacing context requires
an iframe reload. Receiving context does not perform host initialization or
load conversation history unless multiple conversations are enabled.

The parent selects theme through presentation settings. `auto` follows browser
appearance, including changes while open.
The embedding iframe should use `color-scheme: light dark` to keep its transparent
canvas compatible with either browser scheme. The chat controls apply the
configured widget theme independently of that canvas.
The trusted host may provide `stylesheet_url` as an HTTP(S) URL or a root-relative
asset path; the widget loads it inside the iframe. Theme defaults use the
`zaq-widget-theme` CSS layer so an unlayered custom stylesheet can override
`--zaq-widget-*` variables on `:root`, regardless of asset loading order.
Stylesheet URL changes require an iframe reload. Theme and language updates apply immediately.
Origin configuration is checked on HTTP rendering and LiveView mounting;
runtime changes require reloading existing iframes to refresh their HTTP policy.

The widget does not own authentication cookies or user identity resolution.

This allows the same widget to be embedded on authenticated or anonymous host pages.

Example parent context:

```json
{
  "user_id": "user_123",
  "prompt_context": "Current page: /billing. Account type: premium."
}
```

`prompt_context` may steer the agent but must not be treated as an authorization source.

The host should eventually provide verifiable identity if `user_id` is security-sensitive. A raw browser-supplied `user_id` alone is not authentication.

---

## Inbound communication: web_widget -> ZAQ

The widget sends events into ZAQ through the configured `sink_mfa`.

Conceptual flow:

```text
WidgetLive
  -> WebWidget runtime / adapter
  -> sink_mfa
  -> Zaq.Channels.WebBridge.from_listener/3
  -> Incoming / existing ZAQ channel flow
```

The `web_widget` dependency must not hard-code ZAQ modules.

It only knows that it has a configured callback.

### Event shape

`WebWidget.Protocol.Events` prepares inbound event maps without dispatching:

```elixir
{:ok, init} = WebWidget.Protocol.Events.init(widget_id, parent_context)
{:ok, create} = WebWidget.Protocol.Events.create(widget_id, accepted_context, %{id: message_id, content: text})
{:ok, edit} = WebWidget.Protocol.Events.edit(widget_id, accepted_context, %{id: message_id, content: updated_text})
{:ok, history} = WebWidget.Protocol.Events.history(widget_id, accepted_context)
```

These builders accept internal atom-keyed maps and return `{:ok, event_map}` or
`{:error, reason}`. Init/history use `:sync`; create/edit use `:async` and require a
nonblank conversation ID from the host-accepted context. Both message builders
accept an optional fourth argument for the public channel alias (`"default"`
otherwise), and set `timestamp` at build time. The caller supplies and retains
the message ID for edits and retries. Extra input fields are discarded.
Payload preparation does not invoke `sink_mfa` or validate identity/ownership;
host initialization and authorization remain ZAQ's responsibility.

The widget may use its own internal structs, but the callback boundary should be a plain map.

Example:

```elixir
%{
  type: "message.create",
  widget_id: "widget_abc",
  mode: :async,
  user_id: "user_123",
  conversation_id: "conv_123",
  channel: "default",
  message: %{
    id: "msg_456",
    content: "Hello"
  }
}
```

Notes:

- `widget_id` identifies the widget instance.
- `conversation_id` may be `nil` before initialization.
- `message` is an object because it contains multiple meaningful fields.
- Single-value identifiers should stay flat rather than being wrapped in `%{id: ...}`.
- `mode` is chosen by the widget and expresses whether it expects an immediate result.
- Message create/edit requests include a required `timestamp` (`DateTime.t()`), set by the caller when the event is created, for example with `DateTime.utc_now()`.
- `channel` is currently intended as a public routing/agent-selection alias. If the meaning stays agent-specific, consider renaming it later to `route` or `agent_alias` to avoid confusion with ZAQ channel terminology.

---

## Widget initialization

Before the first user message is processed, the widget sends a `widget.init` request.

Conceptual internal struct:

```elixir
%WebWidget.Protocol.Init{
  conversation_id: nil | "conv_123",
  user_id: "user_123",
  mode: :sync | :async,
  prompt_context: "..." | nil
}
```

The transport/callback boundary can still be represented as a plain map.

Example:

```elixir
%{
  type: "widget.init",
  widget_id: "widget_abc",
  mode: :sync,
  conversation_id: nil,
  user_id: "user_123",
  prompt_context: ""
}
```

Typical first-message flow:

```text
Parent page
  -> postMessage(user_id, prompt_context)

User submits first message
  -> widget.init (sync)
  -> ZAQ validates / resolves context
  <- response.widget.initialized

Widget now has conversation_id
  -> message.create (async)
```

A successful synchronous init response should include at least:

```elixir
%{
  type: "response.widget.initialized",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  user_id: "user_123"
}
```

`user_id` is included here so the widget knows which identity context ZAQ accepted/bound.

---

## Multiple conversations and timestamps

Each runtime widget accepts `multiple_conversations: false` (default). Only trusted
runtime configuration enables this feature; browser bootstrap cannot override it.
When enabled, bootstrap loads history without expanding the launcher. The first
message submission opens the conversation and sidebar; typing a draft alone does
not expand it. Bootstrap initializes the host context and requests history with
`include_conversations: true`. The synchronous `response.conversation.history`
payload keeps `messages` for the accepted conversation and adds `conversations`:

```elixir
%{
  messages: [],
  conversations: [
    %{id: "conv_1", title: "Research notes", messages: [
      %{id: "msg_1", role: "user", content: "Hello", timestamp: "2026-10-03T09:00:00Z"}
    ]}
  ]
}
```

ZAQ must return only conversations authorized for the accepted user and widget.
Selection is limited to that list and reinitializes through the host before
subscribing to the selected topic. Switching and New chat are disabled during an
active response. Session updates are cached in LiveView; this is not persistence.
New chat initializes with a null conversation ID on its first submission. The
original parent bootstrap remains immutable across selections.

Message `timestamp` is an optional ISO 8601 timestamp with offset (or DateTime
at the in-process boundary), normalized to ISO 8601. Creation time is preserved
through streaming edits and completion. History messages must be ordered oldest
to newest by the host. Untimestamped legacy history is still
accepted, without inventing historical dates. The UI formats times and calendar
day separators in the browser's local time zone: Today, Yesterday, or a date.
The mock history response supplies three fixture conversations containing 4, 6,
and 7 timestamped messages across yesterday and today.

---

## Implemented delivery boundary

Runtime configuration includes `pubsub_server`, the host-owned Phoenix.PubSub
server name. `sink_mfa: {module, function, args}` is invoked as
`apply(module, function, [event | args])`. Use a host wrapper or configured extra
arguments to adapt an existing bridge signature. Callbacks must return promptly:
init/history return `{:ok, response_map}`, message create/edit return `:ok` once
accepted, and failures return `{:error, reason}`. Callback exceptions are reported
as unavailable, without exposing exception details to the browser.

`WebWidget.Adapter.send_event/1` accepts atom-keyed plain maps and validates the
response namespace and payload. It resolves the PubSub server from the widget's
runtime and publishes to a topic scoped by widget and conversation IDs. LiveView
subscribes after synchronous initialization and before history or message dispatch.
No widget-wide subscription is used for initialization: pre-conversation errors
are returned synchronously. PubSub delivery requires a nonblank conversation ID.

Message edits contain the full replacement text, not token deltas. A create event
must precede edits, steps, completion, or failure for its message ID. Steps update
by step ID within their assistant message; terminal messages/steps cannot regress
on duplicate or late events. Producers must serialize events for each response and stop typing before the
terminal message event, so a delayed typing reset cannot affect the next turn.
Conversation IDs cannot change through unsolicited PubSub events. History is a
snapshot loaded before a resumed conversation accepts a new message.

The development/test mock uses this exact callback and adapter path. It does not
authenticate users or persist history. The mock supplies three dated conversation fixtures; `mock-history` is an alias
for the first. Unknown mock histories are empty. Reconnects reinitialize on
the next submission. PubSub is live delivery, without replay or persistence.

---

## Sync vs async events

The widget owns whether it expects an immediate result.

Use:

```elixir
mode: :sync
```

when the caller waits for the callback result.

Use:

```elixir
mode: :async
```

when the callback only acknowledges acceptance and later results arrive through outbound response events.

Example:

```text
widget.init
mode: :sync

message.create
mode: :async
```

ZAQ may still validate whether a given event supports the requested mode.

### Sync flow

```text
WidgetLive
  -> sink_mfa
  -> WebBridge
  <- {:ok, response}
WidgetLive
```

### Async flow

```text
WidgetLive
  -> sink_mfa
  -> WebBridge
  <- :ok / accepted

Later:

ZAQ
  -> WebWidget.Adapter
  -> PubSub
  -> WidgetLive
```

---

## Inbound events required for V1

### `widget.init`

Initialize the widget context.

Expected fields:

```elixir
%{
  type: "widget.init",
  widget_id: "widget_abc",
  mode: :sync | :async,
  user_id: "user_123",
  conversation_id: nil | "conv_123",
  prompt_context: nil | String.t()
}
```

### `message.create`

Create a user message.

```elixir
%{
  type: "message.create",
  widget_id: "widget_abc",
  mode: :async | :sync,
  timestamp: DateTime.utc_now(),
  user_id: "user_123",
  conversation_id: "conv_123",
  channel: "default",
  message: %{
    id: "msg_456",
    content: "Hello"
  }
}
```

`WebBridge` should translate this into the existing ZAQ `Incoming` / channel flow.

### `message.edit`

Edit an existing user message.

Same base shape as `message.create`, with:

```elixir
type: "message.edit"
```

### `conversation.history.request`

Load persisted conversation history.

Example:

```elixir
%{
  type: "conversation.history.request",
  widget_id: "widget_abc",
  mode: :sync,
  user_id: "user_123",
  conversation_id: "conv_123"
}
```

---

## Outbound communication: ZAQ -> web_widget

ZAQ should not build `WebWidget.Protocol.Response` structs.

`WebBridge` sends plain maps to the adapter:

```text
ZAQ
  -> WebBridge
  -> WebWidget.Adapter
  -> PubSub
  -> WidgetLive
  -> live_react / assistant-ui
```

The adapter may convert maps into internal structs if useful, but that is owned by `web_widget`.

### Why PubSub

Asynchronous agent work may finish in another process.

ZAQ should not keep or propagate LiveView PIDs.

Instead, `web_widget` can route response events by stable identifiers such as:

- `widget_id`
- `conversation_id`

Conceptually:

```text
WebBridge
  -> WebWidget.Adapter.send_event(map)
  -> publish to widget/conversation topic
  -> WidgetLive receives handle_info
  -> LiveView updates browser over its existing WebSocket
```

No custom Phoenix Channel or second browser WebSocket is required.

---

## Outbound event namespace

Everything sent from ZAQ to the widget uses the `response.*` namespace.

Required V1 events:

```text
response.widget.initialized

response.conversation.created
response.conversation.history

response.message.create
response.message.edit
response.message.step
response.message.complete
response.message.failed

response.typing
response.error
```

---

## Outbound payloads

All payloads are plain maps.

### `response.widget.initialized`

```elixir
%{
  type: "response.widget.initialized",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  user_id: "user_123"
}
```

### `response.conversation.created`

```elixir
%{
  type: "response.conversation.created",
  widget_id: "widget_abc",
  conversation_id: "conv_123"
}
```

### `response.conversation.history`

```elixir
%{
  type: "response.conversation.history",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    messages: [
      %{
        id: "msg_1",
        role: "user",
        content: "Hello"
      },
      %{
        id: "msg_2",
        role: "assistant",
        content: "Hi"
      }
    ]
  }
}
```

### `response.message.create`

```elixir
%{
  type: "response.message.create",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    id: "resp_456",
    content: ""
  }
}
```

### `response.message.edit`

Used for streaming or updating the assistant message.

```elixir
%{
  type: "response.message.edit",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    id: "resp_456",
    content: "Here is the answer..."
  }
}
```

### `response.message.step`

Used for visible intermediate activity such as:

- reasoning/status
- tool calls
- tool results

Example:

```elixir
%{
  type: "response.message.step",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    id: "step_1",
    message_id: "resp_456",
    kind: "tool_call",
    state: "started",
    label: "Searching knowledge base",
    content: nil,
    metadata: %{}
  }
}
```

Suggested `kind` values:

```text
reasoning
tool_call
tool_result
status
```

Suggested `state` values:

```text
started
updated
completed
failed
```

### `response.message.complete`

```elixir
%{
  type: "response.message.complete",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    id: "resp_456",
    content: "Final answer"
  }
}
```

### `response.message.failed`

```elixir
%{
  type: "response.message.failed",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    message_id: "resp_456",
    code: "agent_execution_failed",
    message: "Unable to generate a response"
  }
}
```

### `response.typing`

```elixir
%{
  type: "response.typing",
  widget_id: "widget_abc",
  conversation_id: "conv_123",
  payload: %{
    active: true
  }
}
```

### `response.error`

Used for protocol/request failures that may happen before an assistant response exists.

Examples:

- unknown widget
- disabled widget
- invalid conversation
- unsupported event
- invalid initialization
- invalid identity context

```elixir
%{
  type: "response.error",
  widget_id: "widget_abc",
  conversation_id: nil,
  payload: %{
    request_type: "widget.init",
    code: "invalid_user",
    message: "Unable to initialize widget"
  }
}
```

---

## Conversation ownership

ZAQ owns durable conversation history.

The widget should not resend complete history with every message.

The widget only keeps the current `conversation_id`.

```text
Widget refresh / reconnect
  -> conversation.history.request
  -> ZAQ loads persisted messages
  <- response.conversation.history
```

This allows LiveView state to be rebuilt after process loss.

---

## Security / trust boundary

The widget must not send or decide:

- ZAQ actor/person structs
- permissions
- internal agent IDs
- retrieval IDs
- credentials
- internal routing state

ZAQ resolves these internally from trusted configuration and validated widget/user/conversation context.

Parent-provided `prompt_context` may affect prompting but must not grant permissions.

Allowed iframe origins belong to widget runtime configuration and should be enforced when serving the widget.

---

## Design rules

1. Keep the protocol small.
2. Use plain maps at the ZAQ <-> `web_widget` boundary.
3. Use nested objects only when the concept contains multiple meaningful fields.
4. Keep single IDs flat (`widget_id`, `conversation_id`, `user_id`).
5. `message` is nested because it contains both `id` and `content`.
6. `response.*` is reserved for ZAQ -> widget events.
7. `message.*`, `widget.*`, and `conversation.*` are widget -> ZAQ events.
8. `sink_mfa` is the inbound callback into ZAQ, not a transport.
9. PubSub is the asynchronous server-side return path to `WidgetLive`.
10. LiveView's existing WebSocket is the only browser realtime transport.
11. Do not add AG-UI, SSE, or a second WebSocket for this integration.
12. Reuse ZAQ's existing `Incoming`, conversation, routing, and channel abstractions after the WebBridge boundary.
