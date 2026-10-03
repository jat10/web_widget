# WebWidget

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Host Phoenix integration

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
`ReactHook` and connects to the host's `/live` socket. No widget hook imports or
scripts belong in the parent's JS bundle. The iframe does not load the host app
bundle. Currently the endpoint must be root-mounted with the standard `/live` path.

Start each channel's runtime under the host supervisor:

```elixir
{WebWidget.Runtime,
 %{
   channel_config_id: 42,
   sink_mfa: {MyApp.WebBridge, :from_listener, []},
   widgets: [
     %{widget_id: "support", display_name: "Support Assistant", allowed_origins: ["https://customer.com"]}
   ]
 }}
```

Origins must be exact HTTP(S) origins, including any non-default port. Paths,
wildcards, credentials, queries, and fragments are rejected; a trailing slash is
normalized. Missing, null, or empty `allowed_origins` disables the widget, including
same-origin embedding. The route sets CSP `frame-ancestors` from this list and
removes `X-Frame-Options`; unavailable widgets use `frame-ancestors 'none'`.
The browser bootstrap also checks the parent window and allowed origin.
Reload existing iframes after changing origin configuration. The standalone demo
explicitly allows `http://localhost:4000` in development.

For local testing, override the demo origins when starting the development server:

```sh
WEB_WIDGET_DEMO_ALLOWED_ORIGINS=http://localhost:4010 mix phx.server
```

Use a comma-separated list to allow multiple origins. This development-only
override replaces the demo allowlist and requires restarting the server.

The callback is retained but not invoked yet. Widget IDs are globally unique.
HTTP and connected mounts look up the ID afresh. Missing/stopped runtimes render
“Widget unavailable” without chat hooks and reject browser events. This is an
HTTP 200 error screen, not a redirect or HTTP 404. Runtime changes do not revoke
already-mounted views; reconnect/remount checks again. The resolved display name
supplies the document title and conversation header.

Incomplete or malformed paths under the mounted widget prefix (such as `/widget`
or `/widget/support/extra`) return a friendly HTTP 404 without debug details or
chat scripts. Their framing policy remains `frame-ancestors 'none'`. Embedding
pages should show their own unavailable message when a frame cannot load or
does not announce readiness; browsers do not display denied iframe content.

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

Embed `/widget/support` on a configured allowed origin and implement the ready/init
handshake and resize handling below. Host routing/authentication remains the
host's responsibility. Stylesheet URLs, callback dispatch, response PubSub, real initialization and
history remain deferred. The existing mock conversation is unchanged.

## React components

LiveReact 2 integrates React with LiveView. Use Node.js 22 (22.12+) or Node.js 24
and npm; assistant-ui's dependencies do not support Node.js 23. These are required
for the Vite asset pipeline. `mix setup` installs the locked npm dependencies,
and `mix phx.server` starts Vite on `localhost:5173` for demo-page assets.
Widget iframe assets use the built bundle in standalone and host mode; rerun
`mix assets.build` after changing them.

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

## Embedded widget prototype

In development, open `/widget-demo` for a scrolling host page with the widget in a compact iframe. This route is only enabled by the development `:dev_routes` configuration.
`/widget/demo` is the iframe document and requires parent bootstrap
context before displaying the composer. Before the first message, only a floating
composer is shown. Enter sends; Shift+Enter adds a line.
The first submission expands the iframe and displays the conversation. A mocked
search step appears, followed by a deterministic reply. Subsequent messages keep
the same conversation. Responses are explicitly mocked; no external service is called.

`WidgetLive` owns `mode` (`:launcher` or `:conversation`), the message list, pending
reply, and widget configuration. Its `<.react name="WebWidget" ...>` passes these
assigns to `assets/react-components/web-widget.tsx`. React uses assistant-ui's
`useExternalStoreRuntime` to adapt those props; it does not keep another canonical
message list. Only draft input, submission acknowledgement, and errors are local.
`useLiveReact().pushEvent("widget.submit", {text}, callback)` uses the existing
LiveView WebSocket. LiveView validates the text, acknowledges it, and sends props
updates immediately; the mock answer follows after 700ms. No client-side optimistic
message is added, so first rendering depends on one WebSocket round trip.

The React composition is `WebWidget` → `Conversation` (thread, user/assistant
messages, `ResponseStep`) + `FloatingComposer`. It reuses assistant-ui's runtime
provider, thread root/viewport/messages/scroll control, message parts, and composer
root/input/send primitives. A response step is plain prototype data:
`{type: "response.step", kind: "tool_call", text, status}`. This is not a WebBridge protocol.

### iframe sizing and customization

The iframe sends `{type: "zaq.widget.ready"}` when its LiveView listener is ready
and after reconnection. Reply from the parent with the iframe's exact origin:

```js
const widgetOrigin = new URL(iframe.src, window.location.href).origin;
window.addEventListener("message", (event) => {
  if (event.source !== iframe.contentWindow || event.origin !== widgetOrigin) return;
  if (event.data?.type !== "zaq.widget.ready") return;
  iframe.contentWindow.postMessage({
    type: "zaq.widget.init",
    user_id: "user_123",
    prompt_context: "Current page: /billing",
    conversation_id: null,
  }, widgetOrigin);
});
```

Register this listener before loading the iframe so you receive its ready message.
Only parents listed in the widget’s `allowed_origins` can embed it. The demo handles this
handshake automatically. `user_id` is required; the other fields default to null. `prompt_context` accepts
a string only (or null), not a JSON object. The chat UI remains hidden until valid
context arrives. Invalid messages or five seconds without valid context produce
a developer console error explaining how to send `zaq.widget.init` after
`zaq.widget.ready`. A later valid message unlocks the UI. Opening `/widget/demo`
directly has no parent to initialize it; use `/widget-demo` or an embedding page.
LiveView retains the context without exposing it in React props or treating it as
authenticated identity. Identical retries are safe; changing context requires an
iframe reload. Host initialization and conversation-history loading are not yet
connected.

React sends `window.parent.postMessage({type: "zaq.widget.resize", mode, height}, "*")`
on mode and size changes. Launcher height is measured from the composer; conversation
height is `"100%"`. No message content is included. The demo listener in
`assets/js/widget-demo.ts` validates both `event.source` and the same-site origin,
then changes only the iframe dimensions. The compact iframe leaves host content
clickable and scrollable. This listener is a demo, not a parent SDK.

Defaults live in `assets/css/widget.css`. Override `--zaq-widget-primary`,
`--zaq-widget-background`, `--zaq-widget-text`, `--zaq-widget-radius`,
`--zaq-widget-font-family`, or `--zaq-widget-composer-background` inside the widget
document. Parent-page CSS does not cross the iframe boundary. No stylesheet URL API
is implemented.

### Validation and limitations

```sh
mix assets.build
mix precommit
cd assets
npx playwright install chromium
npm run test:e2e
```

The browser tests start the standalone demo on port 4019 and a minimal host endpoint on port 4020 and verify
the real React → LiveView → React flow, desktop/mobile layout, iframe expansion,
Enter/Shift+Enter behavior, mock steps, and preserved follow-up messages. Set
`PLAYWRIGHT_CHROMIUM_BIN` to use an existing Chromium executable.

State lasts only for the LiveView process; reloads or a new connection after process
loss reset it. One response runs at a time. There is no persistence, authentication,
cancel/retry protocol, real tools, or ZAQ integration. A submission timeout can be
ambiguous if the server accepted it; reliable retries will need request IDs when
the real protocol is introduced. Embedding uses the configured origin allowlist and CSP `frame-ancestors`.
Hosts remain responsible for their session policy. Mobile sizing uses `dvh`; real-device keyboard behavior still needs
validation. Nothing in the UI requires another transport: a future WebBridge adapter
can update LiveView-owned messages and steps through the same props boundary.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
