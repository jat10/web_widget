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
   sink_mfa: {MyApp.WebBridge, :from_widget, []},
   pubsub_server: MyApp.PubSub,
   widgets: [
     %{widget_id: "support", display_name: "Support Assistant", allowed_domains: ["https://customer.com"]}
   ]
 }}
```

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

The callback receives the event followed by its configured arguments. It returns
`{:ok, response_map}` for synchronous init/history requests, `:ok` for accepted
asynchronous messages, or `{:error, reason}` on rejection. Host asynchronous
responses enter through `WebWidget.Adapter.send_event/1`, which validates plain
maps and publishes on the configured PubSub server. See the
[adapter contract](docs/adapter-contract.md#implemented-delivery-boundary).
Widget IDs are globally unique.
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
host's responsibility. The ZAQ-side bridge remains deferred. Callback dispatch,
response PubSub, initialization, and history loading use the shared host boundary.

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
updates after host acceptance. Mock response events arrive at 350ms intervals. No client-side optimistic
message is added, so first rendering depends on one WebSocket round trip.

The React composition is `WebWidget` → `Conversation` (thread, user/assistant
messages, `ResponseStep`) + `FloatingComposer`. It reuses assistant-ui's runtime
provider, thread root/viewport/messages/scroll control, message parts, and composer
root/input/send primitives. Tool calls and results arrive as
`response.message.step` events and update by step ID within their assistant message.
React groups tool activity into expandable cards with progress badges and
collapsible results. Activity opens while running, folds into a summary on
completion, and stays open on failure. Streaming answers show a writing indicator;
failed responses show a dedicated error panel. Arbitrary metadata is not sent
to the browser.

The standalone mock is explicitly enabled in development/test configuration via
`:mock_host`. Its modules live in `test/support/demo`, compiled in development
and test only. The development build includes this directory without loading
other test support modules. Production builds exclude both mocks.
It is not started by a dependency host or production defaults.
Try these messages in `/widget-demo` or the local playground:

| Message | Scenario |
| --- | --- |
| `hello` | Streamed greeting without tools |
| `search` | Tool progress, result, then streamed answer |
| `research` | Two independently updated tool calls |
| `fail` | Tool failure and message failure; another message can be sent |
| `slow` | Slower tool/streaming events |
| Any other text | Default search scenario |

Set `multiple_conversations: true` on a runtime widget to show the conversation
sidebar and **New chat** button. The flag defaults to `false` and cannot be set
by parent-page bootstrap. With it enabled, history loads after bootstrap with
three mock conversations containing 4, 6, and 7 messages from yesterday and today.
The widget stays in its compact launcher until the user sends the first message;
loading history does not open it.
Messages show local times and calendar-day separators. Selecting a conversation
revalidates it through the host; switching is disabled while a response is running.
Completed session updates survive switching, and New chat starts a separate
conversation on its first submission.

To enable this in the standalone development demo without editing configuration,
restart the server with:

```sh
WEB_WIDGET_DEMO_MULTIPLE_CONVERSATIONS=true mix phx.server
```

Combine this with `WEB_WIDGET_DEMO_ALLOWED_DOMAINS` if using the playground.
The regular demo URL remains `/widget-demo`. Set the parent conversation ID to
`mock-weekend`, `mock-billing`, or `mock-research` to start with a fixture;
`mock-history` remains an alias for the first history. Unknown mock histories are empty; the mock does not
persist or authenticate conversations. `WebWidget.MockHost` emits plain maps
through the same `Adapter.send_event/1` used by ZAQ. `WebWidget.Conversation.State`
reduces those events into LiveView-owned state, with stable message and step IDs.
Switching to ZAQ requires configuring its callback and PubSub server and sending
responses to the adapter, without changing the React components.

The header’s **Close chat** button collapses the widget to its launcher without
ending the conversation or cancelling the response. **Open conversation** restores
the thread, including messages received while closed and any unsent draft. The
demo restores host-page scrolling when the iframe returns to launcher mode.

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
Only parents listed in the widget’s `allowed_domains` can embed it. The demo handles this
handshake automatically. `user_id` is required; the other fields default to null. `prompt_context` accepts
a string only (or null), not a JSON object. The chat UI remains hidden until valid
context arrives. Invalid messages or five seconds without valid context produce
a developer console error explaining how to send `zaq.widget.init` after
`zaq.widget.ready`. A later valid message unlocks the UI. Opening `/widget/demo`
directly has no parent to initialize it; use `/widget-demo` or an embedding page.
LiveView retains the context without exposing it in React props or treating it as
authenticated identity. Identical retries are safe; changing context requires an
iframe reload. The first submission initializes through the host callback,
subscribes to the accepted conversation topic, and loads history when resuming
a conversation before dispatching the message.

React sends `window.parent.postMessage({type: "zaq.widget.resize", mode, height}, "*")`
on mode and size changes. Launcher height is measured from the composer; conversation
height is `"100%"`. No message content is included. The demo listener in
`assets/js/widget-demo.ts` validates both `event.source` and the same-site origin,
then changes only the iframe dimensions. The compact iframe leaves host content
clickable and scrollable. This listener is a demo, not a parent SDK.

Theme is controlled by CSS inside the iframe, not ZAQ runtime configuration.
Set `--zaq-widget-color-scheme: light` or `dark` for a fixed palette, or
`light dark` (the default) to follow browser appearance changes immediately.
Set `style="color-scheme: light dark"` on the embedding `<iframe>` so its canvas
stays transparent on both light and dark host pages. The demo includes this.

Set `stylesheet_url: "https://your-site.example/widget.css"` (or a root-relative
asset path) to load custom CSS inside the iframe. The URL is trusted host
configuration; parent messages cannot change it. A failed stylesheet leaves the
built-in theme available. Reload the iframe after configuration changes.

Defaults live in `assets/css/widget.css` in the `zaq-widget-theme` cascade layer. Override `--zaq-widget-primary`,
`--zaq-widget-background`, `--zaq-widget-text`, `--zaq-widget-radius`,
`--zaq-widget-font-family`, or `--zaq-widget-composer-background` inside the widget
document. Parent-page CSS does not cross the iframe boundary. Use unlayered CSS
so your overrides take priority even when the widget CSS loads afterward:

```css
:root {
  --zaq-widget-color-scheme: dark;
  --zaq-widget-primary: #7356c7;
  --zaq-widget-on-primary: #fff;
  --zaq-widget-radius: 12px;
}
```

The built-in palettes follow ZAQ chat’s foundation and semantic colors. Surface
colors can also be overridden with `--zaq-widget-elevated`,
`--zaq-widget-accent-background`, and `--zaq-widget-border`.

Other color tokens include `--zaq-widget-muted`, `--zaq-widget-shadow`, and
`--zaq-widget-error-border`, `--zaq-widget-error-background`,
`--zaq-widget-error-text`, and `--zaq-widget-error-badge`. Custom color tokens can use `light-dark(lightColor, darkColor)` to follow the
selected CSS color scheme.

### Elixir quality and coverage

Like ZAQ, `mix q` runs formatting, strict Credo, and
compilation with warnings treated as errors. ZAQ-specific hook and documentation
tasks are not part of this standalone project.

- `mix q` — fix formatting and run quality checks.
- `mix precommit` — check formatting, run strict Credo, compile, and run all tests.
- `mix coveralls` — run tests and print coverage.
- `mix coveralls.html` — write a browsable report to `cover/excoveralls.html`.
- `mix coveralls.json` — write machine-readable coverage to `cover/excoveralls.json`.
- `mix coverup [threshold] [limit]` — read that JSON report and list changed Elixir
  files below the threshold with their uncovered line numbers (defaults: 95%, 20
  files). Run `mix coveralls.json` first. Requires Git, jq, and a local `main`
  branch; considers `main...HEAD`, staged, and unstaged tracked changes under
  `lib/`. Untracked files and files missing from the report are not included.

The local [coverage-upper skill](.agents/skills/coverage-upper/SKILL.md) coordinates
fresh report generation, test planning, and focused test implementation using the
supporting skills in `.agents/skills/`.

Coverage tasks automatically use the test environment. Reports exclude dependencies
and test support code; application code, including Phoenix components, is counted.
CI runs strict Credo and coverage for every build and saves the report as an artifact.
To enable Coveralls uploads, activate this repository in Coveralls and add its token
as the GitHub Actions secret `COVERALLS_REPO_TOKEN`. Fork PRs generate local reports
without uploading.

### Validation and limitations

```sh
mix assets.build
mix precommit
cd assets
npx playwright install chromium firefox webkit
npm run test:e2e
```

The browser tests run on Chromium, Firefox, and WebKit. To run one browser, use
`npm --prefix assets run test:e2e -- --project=firefox` from the repository root.
CI runs each browser in a separate job and saves its artifacts separately.
The tests start the standalone demo on port 4019 and a minimal host endpoint on port 4020 and verify
the real React → LiveView → React flow, desktop/mobile layout, iframe expansion,
Enter/Shift+Enter behavior, mock steps, and preserved follow-up messages. Set
`PLAYWRIGHT_CHROMIUM_BIN` to use an existing Chromium executable; this override
applies only to the Chromium project.

Recovery tests also start a loopback-only control server on port 4021. The
Playwright-only host can reject a request once, hold a response until released,
and retain session history for reconnect checks. These controls are loaded by
`assets/tests/server.exs` and are not mounted in application routes.

State lasts only for the LiveView process; reloads or a new connection after process
loss reset it. One response runs at a time. There is no persistence, authentication,
cancel/retry protocol, real tools, or ZAQ integration. A submission timeout can be
ambiguous if the server accepted it; reliable retries will need request IDs when
request retry support is introduced. Embedding uses the configured origin allowlist and CSP `frame-ancestors`.
Hosts remain responsible for their session policy. Mobile sizing uses `dvh`; real-device keyboard behavior still needs
validation. The ZAQ bridge can deliver events through `WebWidget.Adapter.send_event/1`;
browser updates continue over the existing LiveView WebSocket.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
