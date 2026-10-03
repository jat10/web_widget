# Web Widget Agent Entry Point
`web_widget` is a Phoenix LiveView widget application using `live_react` and assistant-ui. This file is the agent dispatcher, not a duplicate of project documentation.

## Load instructions by task

- Before changing Elixir, Phoenix, LiveView, supervision, or OTP code, read [Elixir guidelines](docs/elixir-guidlines.md).
- Before changing ZAQ integration, adapter/runtime behavior, widget events, conversation flow, PubSub delivery, or iframe integration, read [Adapter contract](docs/adapter-contract.md).
- Read only the documents relevant to the task. Do not duplicate their rules into code comments or new docs unless required.

## Essential constraints

- Keep `web_widget` independent from ZAQ internals. The integration boundary uses plain maps and configured callbacks/adapters.
- Browser realtime communication uses the existing LiveView WebSocket. Do not add AG-UI, SSE, or a second browser WebSocket unless explicitly required.
- `sink_mfa` is an inbound callback into the host application, not a transport.
- ZAQ owns routing, permissions, identity resolution, and durable conversation state.
- `web_widget` owns iframe delivery, LiveView/browser state, assistant-ui presentation, parent `postMessage` handling, and delivery of host response events to the correct widget.
- Preserve the `response.*` namespace for host -> widget events.
- Keep protocol and runtime changes small and reuse existing abstractions before introducing new ones.
- Add focused tests for changed behavior and do not weaken existing assertions.

## Task map

| Work | Read first |
| --- | --- |
| Elixir / Phoenix / LiveView / OTP | [Elixir guidelines](docs/elixir-guidlines.md) |
| ZAQ adapter integration | [Web Widget adapter contract](docs/web_widget_adapter_contract.md) |
| Event contract / sync-async behavior | [Web Widget adapter contract](docs/web_widget_adapter_contract.md) |
| Widget runtime config / iframe / PubSub | [Web Widget adapter contract](docs/web_widget_adapter_contract.md) |
| React / assistant-ui UI work | Inspect the existing React components and preserve the LiveView ownership boundary |

## Working rule

If the implementation conflicts with the documented adapter contract, stop and update the contract decision first rather than silently introducing a second integration model.
