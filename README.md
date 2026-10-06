# ZAQ Web Widget

Embed a floating ZAQ chat on a website with one installation script. The script creates and positions an iframe; the chat runs inside it, so the website's styles and JavaScript stay separate from the widget. ZAQ owns agent routing, identity resolution, permissions, and durable conversations. This package owns the iframe, browser state, and chat presentation.

## Features

- Chat with a ZAQ agent through the existing LiveView connection, including live response updates, typing status, and conversation resume.
- A copyable installation script in ZAQ's Web Widget back office. It mounts the iframe automatically and includes no credentials.
- Backend-signed, five-minute HS256 identity tokens scoped to a widget and user. The website keeps the connector authentication key on its backend.
- Light (default), dark, and automatic themes; English, French, and Arabic controls, with right-to-left layout for Arabic.
- A parent-page API for initialization and settings: `zaq.widget.init`, `getSettings`, and `updateSettings`. Conversation and authentication-renewal events help the host website keep a chat open across page loads.
- Responsive floating launcher and full-height chat.

Response activity is displayed when the host supplies it. ZAQ's current widget response path sends generic activity steps rather than public tool-call details, so a tool call visible in ZAQ's back office may not appear as a named tool in the widget.

| Light theme | Dark theme |
| --- | --- |
| ![Widget in light theme](docs/screenshots/light-theme.png) | ![Widget in dark theme](docs/screenshots/dark-theme.png) |

The screenshots show the local demo with mock responses.

## Integrate on your website

Create and enable a Web Widget configuration in ZAQ's back office at `/bo/channels/retrieval/web_widget`. Add your website's exact origin to **Allowed embedding origins** and save the generated **Authentication key** in your website backend's secret store. Then paste the configuration's installation script into your website:

```html
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js" data-widget-id="42" defer></script>
```

To place the widget inside a div, add `iframe-location-id` with its CSS selector:

```html
<div id="zaq-widget" style="width: 100%; height: 600px;"></div>
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js"
        data-widget-id="42" iframe-location-id="#zaq-widget" defer></script>
```

Give the div an explicit height and include it before the script runs. The iframe
fills the div, including when a conversation opens; the parent page remains scrollable.
The child iframe uses `id="zaq-widget-frame"` when the div owns `id="zaq-widget"`.
The same `zaq.widget.init`, `updateSettings`, and `dispose` API applies.
Omit `iframe-location-id` for the default floating widget. Invalid selectors or
missing divs raise an error. Only one widget is supported by the global API.

The script creates the iframe. Your backend signs a JWT with the authentication key, and your frontend passes only that JWT to the widget:

```js
const response = await fetch("/api/widget-identity", { method: "POST", credentials: "same-origin" });
if (!response.ok) throw new Error("Could not authenticate the widget");
const { identity_token } = await response.json();
await zaq.widget.init({ identity_token });
```

Add initialization code after `embed.js` has loaded. The backend must derive the user ID from its authenticated session and sign the token; a browser-supplied `user_id` is not accepted by the integrated widget. The [website integration guideline](docs/integration-guideline.md) gives the complete backend signer, frontend wiring, conversation resume, renewal, and settings examples.

Set presentation independently of identity:

```js
const settings = await zaq.widget.getSettings();
await zaq.widget.updateSettings({ theme: "dark", language: "fr" });
```

| Setting | Values | Default |
| --- | --- | --- |
| `theme` | `"light"`, `"dark"`, `"auto"` | `"light"` |
| `language` | `"en"`, `"fr"`, `"ar"` | `"en"` |

`auto` follows the visitor's browser appearance. Language changes widget controls and errors, not the agent's response language. The settings API merges supplied fields and leaves the conversation intact.

For a Phoenix application hosting this package, see [host integration](docs/host-integration.md) and the [adapter contract](docs/adapter-contract.md). The package has no compile-time dependency on ZAQ internals.

## Run the demo locally

Prerequisites:

- Elixir and Erlang/OTP. CI currently uses Elixir 1.19.5 and OTP 28.1.
- Node.js 22.12+ in the 22 series, or Node.js 24, with npm.
- PostgreSQL. Development defaults are configured in [config/dev.exs](config/dev.exs).

```sh
mix setup
mix phx.server
```

Open `http://localhost:4000/widget-demo`. The demo uses the same `embed.js` installation script to create its iframe, then supplies mock identity and responses. The demo's unsigned bootstrap is for fixtures only; ZAQ integration requires a signed JWT. You can select startup settings with `/widget-demo?theme=dark&language=ar`, or run `zaq.widget.updateSettings(...)` from the parent-page browser console.

| Message | Demo response |
| --- | --- |
| `hello` | Streamed greeting. |
| `search` | One tool call, result, and streamed answer. |
| `research` | Two tool calls with independent progress. |
| `fail` | Tool and message failure, followed by the ability to send again. |
| `slow` | Slower tool and streaming events. |

The demo uses a mock host, not a live ZAQ agent. Enable its conversation sidebar with `WEB_WIDGET_DEMO_MULTIPLE_CONVERSATIONS=true mix phx.server`. To embed the local demo on another origin, set `WEB_WIDGET_DEMO_ALLOWED_DOMAINS` to a comma-separated list of exact allowed origins and restart the server.

Iframe and embed assets use the built bundle. Run `mix assets.build` after changing them; the Vite development watcher alone does not rebuild those assets.

The library provides `mix web_widget.assets.install`: run it from a host such as ZAQ to copy
the built bundle into that host's `priv/static/web_widget/assets`. Add `web_widget`
to the host's static-path allowlist to serve it through the existing static plug,
without `WebWidget.Static`. Reinstall after each widget rebuild and before the
host's production asset digest. See [host asset installation](docs/host-integration.md#install-assets-into-the-host).

## Contributing

Contributions to behavior, accessibility, translations, documentation, and tests are welcome.

1. Fork or clone the repository and create a branch for your change.
2. Follow the local setup above and read [AGENTS.md](AGENTS.md), the [Elixir guidelines](docs/elixir-guidlines.md), and the [adapter contract](docs/adapter-contract.md) where relevant.
3. Make a focused change and add tests for the behavior it affects. Update documentation when changing the public API.
4. Run the checks below and open a pull request describing the problem, the change, and how you tested it. Include screenshots for visual changes.

### Project layout

| Path | Responsibility |
| --- | --- |
| `lib/web_widget/` | Host runtime, adapter, routing helpers, and event contracts. |
| `lib/web_widget_web/` | LiveView state, rendering, and standalone demo. |
| `assets/react-components/` | React and assistant-ui presentation. |
| `assets/js/` | Parent embed client and iframe messaging. |
| `assets/css/` | Widget and demo styles. |
| `priv/gettext/` | UI translation catalogs for English, French, and Arabic. |
| `test/` | Elixir tests. |
| `assets/tests/` | Playwright browser tests and mock host fixtures. |

Keep canonical browser conversation state in LiveView. Use plain maps for UI events and inputs to the host-supplied shared constructors, following the [adapter contract](docs/adapter-contract.md); keep the package independent of ZAQ internals. Browser updates use the existing LiveView WebSocket. The adapter verifies parent identity, while ZAQ owns People resolution, routing, permissions and durable state. Host response events use the `response.*` namespace.

### Checks

```sh
mix assets.build
mix precommit
```

The asset build checks TypeScript and produces widget, client, and embed bundles. `mix precommit` checks formatting, runs strict Credo, compiles with warnings as errors, and runs the Elixir tests.

For browser changes, install Playwright's browsers once and run the relevant tests:

```sh
cd assets
npx playwright install chromium firefox webkit
npm run test:e2e
```

From the repository root, run a single browser or test file with:

```sh
npm --prefix assets run test:e2e -- --project=firefox
npm --prefix assets run test:e2e -- themes.spec.ts
```

The suite runs against real iframe, React, and LiveView code with mock host responses. Its servers use ports 4019, 4020, and 4021; run one suite at a time. CI runs Chromium, Firefox, and WebKit separately. Real-device mobile keyboard behavior still needs manual validation.

For Elixir coverage:

```sh
mix coveralls.json
mix coverup 95 20
```

`coverup` lists changed Elixir files below the target with uncovered line numbers. It requires a fresh coverage report, Git, jq, and a local `main` branch. Use `mix coveralls.html` for a browsable report.

### Translations

Widget UI strings come from [Localization](lib/web_widget_web/localization.ex) through Gettext and are passed to React. When adding a UI string, update the English, French, and Arabic catalogs under `priv/gettext/` and test the affected UI, including Arabic layout. Do not translate host-provided response content in the widget.
