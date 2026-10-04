# Phoenix host integration

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
`ReactHook` and connects to the host's `/live` socket. Widget hooks run inside the iframe. The embedding website separately loads
`/web_widget/assets/embed.js` to expose the parent-side `zaq.widget` API. The iframe does not load the host app
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
[adapter contract](adapter-contract.md#implemented-delivery-boundary).
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

Embed `/widget/support` on a configured allowed origin using the
[website setup instructions](../README.md#add-the-widget-to-your-website). The embed
script handles readiness and resizing. Host routing/authentication remains the
host's responsibility. The ZAQ-side bridge remains deferred. Callback dispatch,
response PubSub, initialization, and history loading use the shared host boundary.

