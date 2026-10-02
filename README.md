# WebWidget

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## React components

LiveReact 2 integrates React with LiveView. Use Node.js 22 (22.12+) or Node.js 24
and npm; assistant-ui's dependencies do not support Node.js 23. These are required
for the Vite asset pipeline. `mix setup` installs the locked npm dependencies,
and `mix phx.server` starts Vite on `localhost:5173` automatically.

Add JSX or TSX components under `assets/react-components` and register them in
`assets/react-components/index.js`. Render a registered component from a LiveView:

```heex
<.react name="Simple" socket={@socket} />
```

Additional assigns become React props. Server-side rendering is disabled;
components render in the browser after LiveView connects.

Run `mix assets.build` to check TypeScript and bundle assets, or
`MIX_ENV=prod mix assets.deploy` to build and digest production assets.
See the [LiveReact documentation](https://hexdocs.pm/live_react/) for component APIs.

## Assistant UI

Visit `/assistant` to preview the registered `AssistantUI` React component:

```heex
<.react id="assistant-ui" name="AssistantUI" socket={@socket} title="Assistant" />
```

The component lives in `assets/react-components/assistant-ui.tsx` and uses
`@assistant-ui/react` with the existing Tailwind theme. It is loaded on demand.
The composer stays disabled until a chat backend is connected; no API calls or
simulated replies are configured.

To connect a backend, supply a `ChatModelAdapter` through the component's
`adapter` prop from a React wrapper and register that wrapper with LiveReact.
Functions cannot be passed from HEEx as serialized props. The adapter handles
requests and cancellation; keep provider credentials on the server.
See [assistant-ui's LocalRuntime guide](https://www.assistant-ui.com/docs/runtimes/custom/local-runtime).

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
