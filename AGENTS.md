# Web Widget Agent Entry Point
`web_widget` is a Phoenix LiveView widget application using `live_react` and assistant-ui. This file is the agent dispatcher, not a duplicate of project documentation.

## Beadwork

- Run `bw prime` before starting work to load current workflow context and repository state.
- Track multi-step work, dependencies, progress, and decisions with `bw`; issues use the `ww` prefix and live on the separate `beadwork` Git branch.
- Use `bw ready` to find unblocked work and `bw comment <id> "..."` to preserve findings and handoff notes. Close completed issues and run `bw sync` to share tracking state.
- Follow the user's requested delivery mode and the harness's permission, delegation, and worktree constraints; Beadwork instructions do not override them.

## Serena

- Before coding, read Serena's `initial_instructions` and activate this repository's root as the project; verify that the active project is `web_widget`.
- Read `mem:core` and follow references to task-relevant memories, including `mem:frontend/core` for React / assistant-ui work. Repository instructions and current code remain authoritative.
- Prefer Serena's symbol navigation, reference lookup, and symbol editing tools when appropriate. Use file tools for non-code files and small edits, or when Serena does not support the file's language.

## Context Mode

- Use Serena for source symbols and relationships; use Context Mode for large operational output and aggregate analysis. Use the exposed `ctx_*` tools with their actual host prefixes.
- Route builds, tests, install logs, large diffs, broad textual searches and structured-data analysis through `ctx_execute`, `ctx_execute_file` or `ctx_batch_execute`. Filter and summarize inside the tool; return concise findings instead of raw logs.
- Use `ctx_index` when later retrieval is useful and `ctx_search` for indexed observations or session recall. Do not index the source tree merely to locate a symbol, or dump large output into context before indexing it.
- Batch independent operations; sequence dependent commands and shared-state work. Keep direct shell/file tools for short bounded observations, targeted Markdown/configuration reads and edits.
- Verify recalled information against current files and Git state. Automatic session capture depends on the integration; do not assume complete history or that Context Mode can wrap Serena calls.
- If Context Mode is unavailable, report the limitation and use bounded output or saved logs with targeted excerpts. Host tool requirements take precedence.

## Load instructions by task

- Before changing Elixir, Phoenix, LiveView, supervision, or OTP code, read [Elixir guidelines](docs/elixir-guidlines.md).
- Before changing ZAQ integration, adapter/runtime behavior, widget events, conversation flow, PubSub delivery, or iframe integration, read [Adapter contract](docs/adapter-contract.md).
- Read only the documents relevant to the task. Do not duplicate their rules into code comments or new docs unless required.

## Essential constraints

- Keep `web_widget` independent from ZAQ internals. Follow the adapter contract for plain-map inputs/UI events and host-supplied shared constructor hooks; do not add a compile-time ZAQ dependency.
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
| ZAQ adapter integration | [Web Widget adapter contract](docs/adapter-contract.md) |
| Event contract / sync-async behavior | [Web Widget adapter contract](docs/adapter-contract.md) |
| Widget runtime config / iframe / PubSub | [Web Widget adapter contract](docs/adapter-contract.md) |
| React / assistant-ui UI work | Inspect the existing React components and preserve the LiveView ownership boundary |

## Working rule

If the implementation conflicts with the documented adapter contract, stop and update the contract decision first rather than silently introducing a second integration model.
