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

The parent website owns language and theme, both at startup and while chatting.
ZAQ keeps trusted configuration such as `allowed_domains`, widget identity,
`stylesheet_url`, and host callbacks. Do not put `locale`, `language`, or `theme`
in ZAQ's widget configuration.

Create the iframe **without `src`**, then create the client. The client installs
its listener before navigating the iframe, waits for readiness, and validates
both the sender window and the exact widget origin.

```html
<iframe id="support-chat" title="Support chat"
        style="width: 100%; height: 180px; border: 0; color-scheme: light dark"></iframe>
<script type="module">
  import { createWidgetClient } from "https://chat.example.com/web_widget/assets/widget-client.js";

  const iframe = document.querySelector("#support-chat");
  const widgetUrl = "https://chat.example.com/widget/support";
  const widgetOrigin = new URL(widgetUrl).origin;
  const onResize = (event) => {
    if (event.source !== iframe.contentWindow || event.origin !== widgetOrigin) return;
    const data = event.data;
    if (data?.type !== "zaq.widget.resize") return;
    if (data.mode === "conversation") iframe.style.height = "100dvh";
    if (data.mode === "launcher" && Number.isFinite(data.height)) {
      iframe.style.height = `${Math.min(260, Math.max(96, data.height))}px`;
    }
  };
  window.addEventListener("message", onResize);
  const widget = createWidgetClient(iframe, widgetUrl);

  // Required identity plus optional context and startup preferences.
  await widget.init({
    user_id: "user_123",
    prompt_context: "Current page: /billing",
    conversation_id: null,
    settings: { theme: "auto", language: "en" },
  });

  // Call these from the website's controls whenever preferences change.
  await widget.updateSettings({ theme: "dark" });
  await widget.updateSettings({ language: "fr" });

  // Optional inspection, never required before an update.
  console.log(await widget.getSettings()); // { theme: "dark", language: "fr" }

  // When removing the iframe:
  // widget.dispose();
  // window.removeEventListener("message", onResize);
</script>
```

Replace the URL and widget ID with your deployment. The parent origin must be in
that widget's `allowed_domains`. The standalone demo is `/widget-demo`; its parent
can select startup settings via `?theme=dark&language=ar`.

| Setting | Values | Default |
| --- | --- | --- |
| `theme` | `"auto"`, `"light"`, `"dark"` | `"auto"` |
| `language` | `"en"`, `"fr"`, `"ar"` | `"en"` |

Updates merge only the supplied fields. Unsupported values, null, arrays, and
unknown keys reject the whole request without applying a partial change. Methods
resolve with effective settings after application, or reject with an error.
They time out after 20 seconds; after a timeout, inspect settings before retrying
because a delayed request may have reached the iframe. No settings request can
change identity, conversation IDs, permissions, origins, or stylesheet URLs.

Language and theme changes preserve drafts, messages, pending replies, and the
selected conversation. Preferences survive LiveView reconnects. A document reload
resets widget defaults; a living parent client automatically reinitializes using
its last accepted context and effective settings. The parent decides whether to
persist preferences across page loads. Repeated init with the same context does
not overwrite runtime settings; changing identity requires a new iframe document.

`user_id` is required. `prompt_context` accepts a string or null, and
`conversation_id` accepts a nonblank string or null; both default to null.
These values remain untrusted until accepted by ZAQ. The chat stays hidden until
valid initialization. The first submission initializes through the host callback
and loads history when resuming a conversation before dispatching the message.

#### Using postMessage directly

The client is optional. Register your listener **before** setting `iframe.src`.
After receiving `zaq.widget.ready` from the expected iframe and origin, send:

```js
iframe.contentWindow.postMessage({
  type: "zaq.widget.init",
  request_id: "init-1",
  user_id: "user_123",
  conversation_id: null,
  prompt_context: "Current page: /billing",
  settings: { language: "ar", theme: "dark" },
}, widgetOrigin);

// Later: partial update, with a unique ID for each request.
iframe.contentWindow.postMessage({
  type: "zaq.widget.settings.update",
  request_id: "settings-2",
  settings: { theme: "light" },
}, widgetOrigin);

// Optional inspection:
iframe.contentWindow.postMessage({
  type: "zaq.widget.settings.get",
  request_id: "settings-3",
}, widgetOrigin);
```

Replies are `{type: "zaq.widget.result", request_id, ok: true, settings: {...}}`
or `{type: "zaq.widget.result", request_id, ok: false, error: "..."}`. Always verify
`event.source === iframe.contentWindow` and `event.origin === widgetOrigin`, then
match the request ID. Invalid senders are ignored. Legacy init without a request
ID still works but receives no acknowledgement. Reply to readiness after reconnects
with the same bootstrap context; the iframe retains its effective settings.

#### Sizing and custom CSS

React sends `window.parent.postMessage({type: "zaq.widget.resize", mode, height}, "*")`
on mode and size changes. Launcher height is measured from the composer; conversation
height is `"100%"`. No message content is included. The demo listener in
`assets/js/widget-demo.ts` validates both `event.source` and the same-site origin,
then changes only the iframe dimensions. The compact iframe leaves host content
clickable and scrollable. This listener is a demo, not a parent SDK.

Language controls Gettext UI strings, validation errors, accessibility labels,
plural summaries, and browser-local dates. Arabic uses right-to-left layout.
Host-provided messages, display names, conversation titles, tool labels, and errors
retain their original text. Translations live in
`priv/gettext/{en,fr,ar}/LC_MESSAGES/widget.po`.

Theme is selected exclusively through settings. `auto` follows browser appearance.
There is no `--zaq-widget-color-scheme` CSS variable. Keep
`color-scheme: light dark` on the **iframe element** to preserve its transparent
canvas; this does not select the widget's theme.

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
