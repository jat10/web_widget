# Development and contributing

For website installation, start with the [integration guide](integration-guideline.md).
For package deployment in Phoenix, use [host integration](host-integration.md).

## Run the demo locally

Prerequisites:

- Elixir and Erlang/OTP. CI currently uses Elixir 1.19.5 and OTP 28.1.
- Node.js 22.12+ in the 22 series, or Node.js 24, with npm.
- PostgreSQL; development defaults are in [config/dev.exs](../config/dev.exs).

```sh
mix setup
mix demo
```

Open `http://localhost:4000/widget-demo`. The demo uses the installation script and
a mock host, not a live ZAQ agent. Its unsigned bootstrap is for fixtures only;
integrated deployments require signed identity tokens. Merely starting the
dependency or running `mix phx.server` does not start widget services.

| Message | Demo response |
| --- | --- |
| `hello` | Streamed greeting. |
| `search` | One tool call, result, and streamed answer. |
| `research` | Two tool calls with independent progress. |
| `fail` | Tool and message failure, followed by the ability to send again. |
| `slow` | Slower tool and streaming events. |

Use `/widget-demo?theme=dark&language=ar` for startup presentation settings.
`WEB_WIDGET_DEMO_MULTIPLE_CONVERSATIONS=true mix demo` enables the conversation
sidebar. To embed the demo on another origin, set
`WEB_WIDGET_DEMO_ALLOWED_DOMAINS` to comma-separated exact origins and restart.
These environment variables belong to the demo, not the host integration API.

## Make a change

Create a branch and read [AGENTS.md](../AGENTS.md), the
[Elixir guidelines](elixir-guidlines.md), and the [adapter contract](adapter-contract.md)
where relevant. Keep changes focused, add tests for changed behavior, and update
documentation for public API changes. Include screenshots for visual changes.

| Path | Responsibility |
| --- | --- |
| `lib/web_widget/` | Runtime, host adapter, routing helpers, and event contracts. |
| `lib/web_widget_web/` | LiveView state, rendering, and standalone demo. |
| `assets/react-components/` | React and assistant-ui presentation. |
| `assets/js/` | Parent embed client and iframe messaging. |
| `assets/css/` | Widget and demo styles. |
| `priv/static/assets/` | Tracked production bundle included in Git tags. |
| `priv/gettext/` | English, French, and Arabic UI translation catalogs. |
| `test/` | Elixir tests. |
| `assets/tests/` | Playwright tests and mock host fixtures. |

LiveView owns canonical browser conversation state. Preserve the existing
LiveView WebSocket and `response.*` event namespace, and keep host integration
independent of ZAQ internals. Follow the adapter contract for boundary changes.

## Build and validate

```sh
mix assets.build
mix precommit
```

The asset build checks TypeScript and produces widget, client, and embed bundles.
The Vite development watcher alone does not rebuild the iframe/embed assets.
Commit changed output in `priv/static/assets` with frontend changes.
`mix precommit` checks formatting, runs strict Credo, compiles with warnings as
errors, and runs the Elixir tests.

For browser changes, install Playwright browsers once and run the relevant tests:

```sh
npm --prefix assets exec -- playwright install chromium firefox webkit
npm --prefix assets run test:e2e
```

Run a single browser or test file with:

```sh
npm --prefix assets run test:e2e -- --project=firefox
npm --prefix assets run test:e2e -- themes.spec.ts
```

The suite uses real iframe, React, and LiveView code with mock host responses.
Servers use ports 4019, 4020, and 4021; run one suite at a time. CI checks Chromium,
Firefox, and WebKit separately. Mobile keyboard behavior also needs real-device
validation.

For Elixir coverage:

```sh
mix coveralls.json
mix coverup 95 20
```

`coverup` lists changed Elixir files below the target with uncovered line numbers.
It requires a fresh coverage report, Git, jq, and a local `main` branch.
Use `mix coveralls.html` for a browsable report.

## Translations

UI strings come from [Localization](../lib/web_widget_web/localization.ex) through
Gettext and are passed to React. Update all three language catalogs for new UI
strings and test Arabic layout. Do not translate host-provided responses.

## Releases and assets

The release workflow runs `npm --prefix assets ci` and
`npm --prefix assets run build`, verifies tracked output, and attaches the bundle
to the GitHub Release. Release Please updates `mix.exs`, `CHANGELOG.md`, tags, and
releases from conventional commits. Git dependency installs use assets committed
in the release tag, not release attachments; hosts do not need to copy or build
the package's assets. See [host integration](host-integration.md#routes-and-assets).
