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
  sink_mfa: {Zaq.Channels.WebBridge, :from_listener, []},
  widgets: [
    %{
      widget_id: "widget_support",
      display_name: "Support Assistant",
      allowed_origins: [
        "https://customer.com"
      ],
      stylesheet_url: "https://customer.com/widget.css"
    }
  ]
}
```

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

The current standalone `/widget` route accepts only same-origin parent messages.
The browser checks both the parent window and origin. LiveView validates the
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
load conversation history. Runtime-configured cross-origin embedding remains
part of the host route integration.

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

`WebWidget.Events` prepares the three inbound event maps without dispatching:

```elixir
{:ok, init} = WebWidget.Events.init(widget_id, parent_context)
{:ok, create} = WebWidget.Events.create(widget_id, accepted_context, %{id: message_id, content: text})
{:ok, edit} = WebWidget.Events.edit(widget_id, accepted_context, %{id: message_id, content: updated_text})
```

These builders accept internal atom-keyed maps and return `{:ok, event_map}` or
`{:error, reason}`. Init uses `:sync`; create/edit use `:async` and require a
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
%WebWidget.Init{
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

ZAQ should not build `WebWidget.Response` structs.

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
    state: "running",
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
