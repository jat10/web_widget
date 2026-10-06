# Project map
- Phoenix LiveView widget with React, live_react and assistant-ui. assistant-ui supplies chat presentation and runtime primitives; LiveView owns canonical conversation state.
- Read AGENTS.md for task dispatch; docs/adapter-contract.md is the existing contract (the task table's docs/web_widget_adapter_contract.md link is stale).
- lib/web_widget: embeddable runtime, router macro, static delivery, event builders and internal payload types. lib/web_widget_web: standalone endpoint, LiveView and rendering.
- Contract includes planned integration; README.md distinguishes implemented host mounting/bootstrap from deferred callback dispatch, history and response delivery. Do not assume conceptual Adapter examples exist.
- Backend source and host integration pointers: `mem:backend/core`. Browser ownership and asset entrypoints: `mem:frontend/core`.
- Build prerequisites: `mem:tech_stack`; commands: `mem:suggested_commands`; editing rules: `mem:conventions`; validation: `mem:task_completion`.
- Memory editing conventions: `mem:memory_maintenance`.
