# Wire ZAQ to web_widget: implementation and smoke-test plan

Date: 2026-10-05. Status: milestones 0, 1 and 1a are complete. BO integration,
runtime/constructor smokes and the single-script loader pass against ZAQ
`c38e7e4e5`. Milestone 2 now implements signed identity and shared-protocol LiveView chat
for the single-node, short-transcript smoke. Live deployment configuration and authenticated iframe acceptance
remain pending; verification used isolated test fixtures.

Scope correction: ZAQ changes are limited to dependency/configuration files and
the generated lockfile. All adapter implementation and new test harnesses belong
to `web_widget`. Earlier proposals below for ZAQ test/module edits are superseded
by this constraint; no such source edits are authorized.

## Follow-up: signed initialization schema

The parent backend now signs exactly `user_id`, `conversation_id` and
`prompt_context` using `SignedIdentity.sign(key, widget_id, init_map, opts)`.
The public authenticated call is only `zaq.widget.init({identity_token})`.
Unsigned overrides, settings, params and unknown fields are rejected at the
browser and server boundaries. Future initialization fields must be added to the
signed schema. Settings use `updateSettings()` separately, including in the demo.
Per-instance stylesheet initialization from the earlier milestone is withdrawn
under this user-requested scope; the shared host constructor remains unchanged.
The follow-up JWT migration replaces Phoenix.Token entirely; old proofs are
rejected and must be issued again as HS256 JWTs.
Resume requires a newly issued token containing the chosen conversation ID;
the frontend no longer rewrites bootstrap context itself. See
[authenticated chat](../authenticated-chat.md) for the revised backend example.

Validation for this follow-up: **143 package tests**, **61 Chromium tests**,
**2 actual ZAQ constructor smokes**, TypeScript/Vite builds, strict Credo and
formatting all passed. Logs: `/tmp/signed-init-checks.log`,
`/tmp/signed-init-browser.log`, `/tmp/signed-init-host.log`,
`/tmp/signed-init-build.log`.

## JWT interoperability follow-up

Replaced Phoenix.Token with JOSE-backed compact JWT/HS256. Signing uses the raw
connector key as UTF-8 HMAC secret, without salt or Base64 decoding. `iss`, `aud`,
`iat`, `exp`, `jti` accompany the three signed init fields and numeric widget ID.
The verifier enforces HS256, header/schema allowlists, five-minute lifetime,
optional `nbf`, scope and replay checks. The browser API is unchanged.

Validation: **145 package tests** and the authenticated Chromium installation/chat/
resume smoke pass. That browser smoke now uses independently Node-signed tokens;
a separate interop test verifies both Node-to-Elixir and Elixir-to-Node signing.
Only JOSE was added to `mix.lock`. ZAQ must fetch the new dependency before restart.
Logs: `/tmp/jwt-checks.log`, `/tmp/jwt-browser.log`.

## Current installation decision — explicit host mount

The subsequent user instruction, "in zaq add the router configuration", authorizes
an exception to the earlier configuration-only constraint: add `import WebWidget.Router`
and a browser-pipeline `/widget` mount in ZAQ's router, plus `plug WebWidget.Static`
in its endpoint. This is now the selected local smoke topology. The old separate
endpoint/proxy recommendations below describe the previous configuration-only option.
ZAQ's existing `/live` socket is reused; no second endpoint or port is needed.
The ngrok tunnel should forward to ZAQ's actual HTTP port (normally 4000), the
installation script should use that public origin, and widget 12 should allow
`http://localhost:4010`. Do not set `public_url` to a separate endpoint for this
setup; remove a stale override or set it to the same public ZAQ origin.

Tracking: `zaq-6c5`. Action reuse is not applicable: this installs existing
transport routes/assets without adding a domain operation. Validation uses
`mix q` and the package-owned `host_mount_smoke.exs` (public HTTP, connected
LiveView, assets and disabled-runtime framing). No changes to host identity,
agent routing or authorization code are part of this exception.

Result: ZAQ `mix q` passed; `MIX_ENV=test mix run
../web_widget/test/support/integration/host_mount_smoke.exs` passed **1 test,
0 failures**. Logs: `/tmp/zaq-widget-mount-q.log` and
`/tmp/zaq-widget-mount-smoke.log`. Live deployment still requires restarting the
existing ZAQ server and enabling the saved connector.

## Outcome and starting point

Install this package into `../zaq`, open a real iframe, send one question through ZAQ's existing Channels → Engine → Agent flow, render the answer, and restore its persisted history. Start with one widget connector, one verified external sender, one conversation and async messages. Keep multiple-conversation listing and user message editing out of the first smoke test.

This plan is based on the [integration handoff at the requested revision](https://github.com/www-zaq-ai/zaq/blob/09386d92694c3a16d25b6e06e4dc866859b80349/docs/guides/web-widget-integration.md) and its [canonical WebBridge contract](https://github.com/www-zaq-ai/zaq/blob/09386d92694c3a16d25b6e06e4dc866859b80349/docs/services/web-bridge.md). The GitHub page could not be fetched, but the exact commit and guide were available locally and read through Git.

Inspected baselines:

| Repository | Revision / observed state |
| --- | --- |
| `web_widget` | `a134225f3f059768be6742cc92acfd1192e1fce7`; existing untracked `docs/exec-plans/` documents retained |
| `../zaq` | `09386d92694c3a16d25b6e06e4dc866859b80349`, branch `refactor/webbridge`, clean at inspection |

### Review of the pulled BO update

Reviewed local commit `c38e7e4e5` against the original baseline, including the
updated guide, shared runtime/command contracts, Engine management boundary,
BO page and associated tests. The sibling working tree still contains only our
dependency/configuration changes (`mix.exs`, `mix.lock`, `config/config.exs`).
The review initially changed this plan only. The milestone 1a execution record
below documents the subsequent package implementation; no additional ZAQ files
were changed.

| Upstream change | Effect on this package and plan |
| --- | --- |
| Dedicated `/bo/channels/retrieval/web_widget` page and Channels card | Use BO to create/edit/enable/archive connectors, select agent routing, and generate/rotate keys. No widget administration page needs building here. |
| `Runtime.status/2` requires both `build/2` and `embed_script/2` | Our builder has only `build/2`, so BO reports the adapter unavailable even if a runtime started through IEx. Add the callback before testing BO enablement. |
| Enablement requires the global base URL | Configure it through System Configuration. The schema also enforces it during persistence, so the earlier IEx recipe needs this prerequisite. |
| `embed_script(widget_id, base_url)` is called by ZAQ | Return escaped, secret-free installation markup matching our actual script/bootstrap API and reachable endpoint. The callback receives no connector key. |
| Connector key is encrypted at rest and delivered as resolved `config.token` | The current builder discards the token and uses a reject-all verifier. Add private per-connector verification and rotation/session revocation before authenticated browser acceptance. Key generation alone does not enable authentication. |
| Persisted `stylesheet_url` is forbidden; hooks no longer include it | Remove the old integration assumption. Optional styling is an absolute HTTP(S) URL in initialization `params.stylesheet_url`, scoped to the iframe instance. Default styling remains bundled. |
| Sink prefix is now `[%{id: id}]` | Generic package invocation already supports it. Update smoke assertions that expect the whole enabled config in the prefix. Never rely on secrets being in sink arguments. |

At review time, the host runtime smoke was stale by inspection: it supplies the now-invalid
persisted stylesheet and asserts the old hook/prefix values. Earlier passing test
counts below remain historical results, not validation of the pulled revision.
No tests were rerun during the initial documentation-only review; refreshed
results are recorded under milestone 1a. Upstream BO tests use
fixture builders; their presence does not demonstrate that our package works.

The older [gap review](zaq-issue-830-gap-review.md) predates this ZAQ implementation. Its recommendations to create a conversation during init and implement the missing host bridge are superseded by the pinned handoff. Milestone 0 updated the [widget contract](../adapter-contract.md) to the selected integration and explicitly separated current implementation gaps from the target contract.

## Decisions for this integration

1. **ZAQ owns the shared protocol.** Call the Message, Command, Context and Delivery constructors supplied in trusted runtime hooks. `web_widget` must not copy their schemas, depend on Engine internals, create People bearers, or request BO capabilities. Constructor inputs and widget UI state remain plain maps; host-provided constructor results are opaque shared boundary values. This explicitly revises the current blanket plain-map-only host contract.
2. **Keep the package independent.** ZAQ depends on `web_widget`, never the reverse. Package modules `WebWidget.Integration.RuntimeBuilder` and `WebWidget.Integration.Protocol` use the supplied modules dynamically, with no compile-time `%Zaq.*{}` references. `WebWidget.Integration.Session` holds server-only verified session state.
3. **One persisted connector equals one widget.** Use the positive integer `hooks.widget_id` for ZAQ context/configuration scope and its string form for the iframe route and widget registry. Do not persist a second `widget_id` setting.
4. **Keep endpoint installation inside the package.** The configuration-only constraint rules out editing ZAQ's endpoint/router. Provide an opt-in package-owned endpoint with its existing LiveView transport, independently of the demo/database startup path. Choose its public origin/path and configuration-based deployment mapping before generating installation URLs. The global ZAQ base URL alone does not prove `/widget` or assets are served there. No SSE, AG-UI or additional browser realtime connection is needed.
5. **Subscribe before first-message admission.** Use a server-generated, unpredictable destination for each authenticated iframe session. Subscribe on `Zaq.PubSub` before submitting a question and put that destination in trusted Delivery. Do not derive it from browser topic/config inputs or require a conversation ID first. Keep that destination stable for the active session; authorize resume separately.
6. **Readiness is not conversation creation.** Opening/init may return a nil conversation ID. The first accepted async question returns its new ID; only that correlated receipt establishes the active conversation. No empty chat should be persisted just to satisfy the old widget initializer.
7. **Identity verification is adapter-owned.** A parent-supplied `user_id` is not authentication. Inject a server-side verifier and retain only its verified external sender and expiry in session state. ZAQ still authorizes People/configuration/conversation access. The earlier [signed identity plan](signed-widget-identity.md) is useful for token lifecycle, but its proposed `widget.authenticate` host operation is not a published ZAQ command: verification belongs before shared Context construction.

## Concrete gaps in the current widget

| Current code / behavior | Required implementation |
| --- | --- |
| `Runtime.dispatch/1` calls `apply(module, function, [event \| args])` | Add an integration boundary which invokes the published sink as `apply(module, function, args ++ [payload, [context: context]])`. Do not point the old dispatcher directly at the new MFA. |
| No builder installed; ZAQ config has only `bridge: Zaq.Channels.WebBridge` | Add the package dependency and configure `runtime_builder`; preserve all other entries in the Channels map. |
| Runtime hooks contain no PubSub server | Supply `Zaq.PubSub` through trusted adapter application configuration for this host; never assume `hooks.pubsub_server` exists. |
| `Events.message_event/4` and `Response.normalize/1` require nonblank conversation IDs | Permit a fresh question and readiness without an ID; continue to require IDs for history/resume and live conversation responses. |
| `WidgetLive.initialize/2` subscribes after init, using the returned conversation ID | Separate verified session/readiness, subscription and active conversation state. Subscribe before first question and handle the creation receipt explicitly. |
| `WidgetLive.submit/2` expects only `:ok` | Consume `{:ok, shared_response}` acceptance, including new ID or resumed `:status`; do not treat it as a terminal answer. |
| Widget receives `{:web_widget_response, event}` on an encoded widget/conversation topic | Add a single shared-response ingress for `{:web_response, event_name, response}` on the authorized session topic. Encode it into existing UI events without republishing to a broader conversation topic. |
| Normalization drops request IDs; reducer checks widget/conversation only | Preserve request/message correlation and reject stale or foreign responses before applying UI state. |
| Bootstrap accepts a browser ID with no proof | Verify identity before readiness, history, subscriptions or sends. Reject missing/expired/foreign proof. |
| History can request an eager `conversations` list | Set `multiple_conversations: false` in this integration. ZAQ publishes bounded conversation history, not the widget's eager conversation-list contract. |
| Builder expects a local stylesheet in runtime hooks | Updated ZAQ omits that hook and forbids persisted stylesheets. Handle optional absolute HTTP(S) URLs during instance initialization instead. |

## Milestone 0 — align the contract and establish a baseline

- [x] Update `docs/adapter-contract.md` and `docs/host-integration.md` to record the decisions above, callback result shapes, lazy creation, session delivery and identity ownership. Preserve the public `response.*` browser/UI namespace.
- [x] Mark incompatible examples and the old gap review as historical; correct the signed-identity proposal, README boundary guidance and AGENTS contract links. Mock implementation migration remains part of milestones 1–2, alongside the production changes.
- [x] Read `docs/elixir-guidlines.md` and the task-relevant ZAQ instructions. Run `bw prime` and inspect existing widget issues. Track subsequent ZAQ implementation through its Beadwork workflow; this file is the cross-repository handoff.
- [x] Run the existing host conformance test as baseline smoke 0:

  ```sh
  cd ../zaq
  mix test test/zaq/channels/web/widget_conformance_test.exs
  ```

This command exists now. With ZAQ's normal test database/services available, it exercises real role dispatch and deterministic external LLM HTTP responses. It proves host conformance only: its `AdapterFixture` does not load this package, its endpoint or its identity verification.

Exit: reviewed contract decisions and a recorded host baseline. If the baseline fails, diagnose that separately before attributing a failure to widget wiring.

### Milestone 0 execution record

Completed 2026-10-05 against the revisions above:

- ZAQ baseline command: exit 0, **2 tests, 0 failures**, seed `903164`, 1.2 seconds
  test execution. Log: `/tmp/web-widget-milestone-0-zaq-baseline.log` (local temporary
  artifact). The command also applied pending migrations in ZAQ's configured test
  database; the ZAQ source working tree remained clean.
- Widget `mix precommit`: exit 0, **104 tests, 0 failures**. Log:
  `/tmp/web-widget-milestone-0-precommit.log` (local temporary artifact).
- Scope: documentation and guidance only. Coverage expansion and new browser tests
  are not applicable here; real-package/iframe acceptance remains pending.
- Action reuse assessment: no executable operation changes in this milestone.
  Subsequent wiring must reuse the existing shared ingress, channel lifecycle and
  canonical history APIs; it does not introduce an Engine operation.
- Beadwork discovery: existing `zaq-kra` covers the package runtime and references
  the older map boundary; `zaq-owg` / `zaq-owg.1` cover the widget route spike.
  Reconcile these with the new wiring scope before milestone 1 code changes. No
  ZAQ implementation ticket was closed or claimed by this documentation milestone.

Next: milestone 1 runtime builder/shared boundary, followed by the lazy-creation
and delivery changes in milestone 2. A passing host fixture is not proof that the
package can already be connected to ZAQ unchanged.

## Milestone 1 — install the runtime and shared-protocol boundary

### ZAQ changes

- [x] Add local development dependency `{:web_widget, path: "../web_widget"}` in `../zaq/mix.exs`. Resolve the host's Phoenix/LiveView/LiveReact dependencies together; do not force incompatible versions. Replace the local path with a reviewed package/revision before distribution.
- [x] In `../zaq/config/config.exs` or the appropriate local config, extend the existing provider entry:

  ```elixir
  web_widget: %{
    bridge: Zaq.Channels.WebBridge,
    runtime_builder: WebWidget.Integration.RuntimeBuilder
  }
  ```

- [x] Configure adapter PubSub and the package-owned reject-all `UnconfiguredIdentity` verifier for runtime checks. Production identity verification remains pending. Do not put verifier credentials, hooks, destinations or module names in connector settings/browser payloads.
- [ ] After milestone 1a, use the BO Web Widget page to save a disabled named connector, configure exact `allowed_domains` and agent routing, generate its key, then enable it with a configured global base URL. The API supports optional `display_name`; the current BO form exposes the connector name. Do not save `stylesheet_url` in settings.

### Package changes

- [x] Implement `RuntimeBuilder.build(config, hooks)` returning `{:ok, {state_spec_or_nil, listener_specs}}`. Reuse `WebWidget.Runtime` for registry/lifecycle state and retain hooks as trusted server-only state. Keep the dependency's standalone endpoint and demo runtime disabled.
- [x] Make the builder's child specs unique per connector and compatible with ZAQ's existing BridgeSupervisor. Validate missing hooks/configuration explicitly; construction errors must fail startup.
- [x] Add the shared-protocol boundary and an explicit authenticated session context. Do not pass authentication authority through browser-editable event maps.
- [x] Preserve the config-bound MFA and integer connector ID. The runtime registry can continue to use the string route ID. Invoke the constructors from `hooks`, then invoke the sink with its configured argument prefix.
- [x] Reject unknown inbound events and all inbound `message.edit` requests. Validate raw resume IDs before constructors: malformed optional IDs must not normalize to nil and silently create a new chat.

Inbound mapping:

| Widget action | Shared operation |
| --- | --- |
| Readiness/init | `Command.new(%{request_id: ..., type: :conversation_init, conversation_id: optional_authorized_id})` |
| History | `Command.new(%{request_id: ..., type: :conversation_history, conversation_id: id, params: bounded_page_params})` |
| First question | `Message.new/1` with request ID, message ID, UTC `DateTime`, channel, async mode, content, nil conversation ID and retained optional parent context |
| Later question | Same Message with accepted conversation ID; do not reseed parent context |

Construct Delivery with `consumer: :widget`, trusted integer configuration ID, session topic and all seven mappings: typing, create, edit, step, complete, failed and error. Construct Context using nil actor, `consumer: :widget`, verified external sender, configuration ID and Delivery. Do not supply agent selection, history, filters or permission bypasses.

Result handling must distinguish a direct semantic Response for commands, `{:ok, Response}` for async acceptance, and `{:error, reason}` before acceptance. Semantic `:error` command responses are also failures, even though they are valid Response values.

Exit: a real runtime starts/stops through ZAQ; a package-owned adapter calls the published sink successfully without a compile-time ZAQ dependency.


### Milestone 1 package execution record

Implemented package-first on 2026-10-05. At that point ZAQ remained unchanged.
The subsequent configuration-only installation is recorded below.

- `RuntimeBuilder.build/2` reads `config :web_widget, :integration`;
  `build/3` accepts explicit `pubsub_server` and `identity_verifier` options.
  Invalid hooks/options/presentation fail construction. The existing Runtime is
  the sole state child, with a connector-specific child ID and no listeners.
- `Runtime.authenticate/2` invokes the verifier with scoped proof and returns a
  process/runtime-generation-bound Session without retaining proof. It refuses
  empty origin allowlists and missing/expired/invalid verification.
- `Runtime.dispatch/2` translates internal requests through supplied constructors
  and invokes the bound MFA with its argument prefix. Raw malformed resume IDs,
  identity/routing overrides, unknown events and edits are rejected. It preserves
  host command/acceptance/error shapes and omits prompt reseeding on resume.
- `Runtime.subscribe/1` subscribes the verified caller to an unpredictable private
  session topic before a conversation exists. The caller owns cleanup via the
  returned subscription handle. Expiry timers/automatic unsubscribe and response
  encoding are still milestone 2/LiveView work.
- The old mock `Runtime.dispatch/1` fails with `:authentication_required` for an
  integrated runtime. Existing mock/browser behavior stays on its current path
  until the coordinated milestone 2 migration; this is not an alternate ZAQ mode.

Boundary analysis (module-context): Runtime owns process-scoped configuration and
registry lifetime; public `fetch_widget/1` exposes presentation only. The builder
owns construction, Protocol owns shared constructor invocation/translation, and
the caller owns its verified Session/subscription. Dependencies are the existing
Registry/PubSub, process-local runtime state, host-supplied modules/MFAs and
application options read only at construction. Flow: builder -> Runtime registry
-> verifier -> Session -> shared constructors -> bound sink. Callbacks execute in
the caller rather than blocking Runtime. Existing runtime tests cover lookup,
registration conflicts and teardown; new tests cover the new boundary. Principal
risks are accidental credential/config leakage, silent nil normalization of resume
IDs and stale-session reuse; tests exercise each. Production proof format and the
LiveView response/expiry lifecycle remain deliberately unresolved implementation
work, not authentication claims made by this milestone.

Validation:

- Focused runtime/integration suite initially passed: 24 tests, 0 failures.
- Final `mix precommit`: **118 tests, 0 failures**, Credo clean. Log:
  `/tmp/web-widget-m1-precommit.log` (local temporary artifact).
- Optional smoke with actual ZAQ constructor sources: **1 test, 0 failures**:

  ```sh
  MIX_ENV=test mix run --no-start test/support/integration/shared_protocol_smoke.exs ../zaq
  ```

  Log: `/tmp/web-widget-m1-constructor-smoke.log`. This loads the six pure shared
  modules from the sibling checkout into an isolated package VM, uses the real
  builder/session/dispatch, and supplies a fixture verifier/sink. It starts no ZAQ
  application/database and verifies constructor compatibility, not real host
  admission, persistence or agent execution.

Next package task is milestone 2: connect WidgetLive to this boundary, consume
creation receipts/shared live events and migrate the mock lifecycle. Merely linking
ZAQ now does not make the existing iframe functional against shared v1.

### Configuration-only ZAQ installation

ZAQ changes are exactly `mix.exs` (local path dependency), `config/config.exs`
(builder, `Zaq.PubSub` and package-owned reject-all verifier) and the generated
`mix.lock` additions for `live_react` and `jsonpatch`. Existing package versions
were preserved. No ZAQ module, endpoint, test or documentation file was edited.

The package provides `WebWidget.Integration.UnconfiguredIdentity.verify/2` so a
channel can start before production identity is implemented. It rejects every
proof; it is not a test-user bypass. A real verifier is required before chat use.

The package-owned host smoke runs from ZAQ:

```sh
MIX_ENV=test mix run ../web_widget/test/support/integration/host_runtime_smoke.exs
```

Result: **1 test, 0 failures**. It calls the existing
`CommunicationBridge.sync_config_runtime/2` with synthetic configuration maps;
it writes no saved channel records. It proves disabled -> enabled, settings and
all shared constructor/config-bound sink hooks reaching the real package runtime,
unchanged-config idempotence, changed-config restart, disable, re-enable and
isolation of two runtimes. The package starts no standalone endpoint/Repo/PubSub.
ZAQ owns one state child with `listener_pids: []`; browser transport continues to
belong to the existing LiveView connection, not a second listener server.

Log: `/tmp/zaq-widget-runtime-smoke.log`. Package `mix precommit` also passed:
**119 tests, 0 failures**, Credo clean. This does not yet verify a browser chat or
send a real agent question. Restart a running ZAQ instance to load the dependency
and configuration before enabling its saved web-widget channel.

ZAQ validation: `mix q` passed; the existing runtime and widget conformance test
files passed together (**9 tests, 0 failures**). Logs:
`/tmp/zaq-widget-config-q.log` and `/tmp/zaq-widget-existing-tests.log`.

## Milestone 1a — adapt to the new BO contract (complete)

Completed package-only; continue with milestone 2.

- [x] Update `docs/adapter-contract.md` and `docs/host-integration.md` first: replace their old local-stylesheet and host-router-edit decisions with the decisions in this review. Keep historical execution records explicitly tied to the old revision.
- [x] Define the package endpoint/public URL configuration and installation markup together. Implement `RuntimeBuilder.embed_script/2` with positive ID and URL validation, HTML attribute escaping, valid nonempty UTF-8 output within 32,768 bytes, and no secrets. Match the real embed client API; do not invent a URL that the package cannot serve. Satisfy the host callbacks without adding a compile-time ZAQ dependency.
- [x] Remove reliance on connector-level stylesheet hooks from the integration builder. Keep custom stylesheet state per iframe, not per runtime; test the actual shared init constructor with valid HTTP(S), omitted, relative and unsupported URLs. Never fetch/proxy CSS on the server. The Protocol already forwards command `params`; browser loading and instance ownership still need work.
- [x] Update `host_runtime_smoke.exs` to omit persisted CSS, expect default presentation styling, and assert `{Zaq.Channels.Web.Runtime, :from_listener, [%{id: id}]}`. Preserve enable/update/disable/isolation assertions. Add real-package checks for host adapter availability and installation snippet generation; do not substitute a fixture builder.
- [x] Update `shared_protocol_smoke.exs` to load the new pure `Zaq.Channels.Web.Stylesheet` dependency alongside Command. Re-run the package checks and both package-owned smoke commands against the new host revision, plus relevant existing host runtime/contracts/BO tests. Record actual results before restoring the current-pass claim.
- [x] BO smoke: configure System Configuration's global base URL; create a disabled connector with an exact parent origin and agent route; generate/provision the key; enable and verify the actual Runtime; copy the snippet and verify its attributes/URLs. Confirm disable tears down the runtime and settings changes restart it. Runtime readiness and copied markup do not constitute a browser chat pass.

Exit: BO recognizes the actual package, can enable/disable it and can copy a
correct installation snippet; refreshed lifecycle/constructor smokes pass.
Signed identity and browser chat remain separate acceptance work below.

### Milestone 1a execution record

Implemented `RuntimeBuilder.embed_script/2` via the pure `Installation.script/3`
helper. It validates connector ID and root HTTP(S) URLs, escapes attributes and
returns one secret-free script tag within the host size limit. Integration
`public_url` selects a separate endpoint; otherwise deployment must proxy widget,
asset and LiveView routes at the global base origin. No proxy is installed by
this callback. `embed.js` reads `data-widget-id`, creates one iframe, attaches
existing client/layout behavior, rejects conflicting frames and removes only its
own iframe on disposal. It never initializes an identity automatically.

The package application now supports `start_integration_server: true`: one
endpoint and socket PubSub, with no Repo, demo or DNS cluster. This brings forward
the minimal endpoint startup separation from milestone 4 so the generated URLs
can be tested against a real listener. Host application configuration and public
URL/proxy deployment are documented in `docs/host-integration.md`; the running
ZAQ installation was not reconfigured by this milestone.

The builder no longer reads stylesheet hooks. Public runtime presentation keeps
`stylesheet_url: nil` for compatibility; the actual shared constructor validates
optional instance stylesheet params. Browser CSS application remains milestone 2.
The reject-all verifier remains in place; BO key rotation restarts the runtime,
but production verification and active-session revocation are not claimed here.

Boundary analysis (module-context): Installation owns markup, not route mounting
or identity. Application owns singleton endpoint infrastructure; ZAQ owns each
connector Runtime; the embed wrapper owns its created DOM node and listeners,
while the existing client owns readiness/settings messages. Flow is BO callback
→ escaped script → package static endpoint → auto-created iframe → existing
LiveView client. Private hooks/configuration never enter markup. Dependencies are
trusted application options (read per callback/startup), HTML escaping, endpoint
configuration, browser DOM and the existing client. Main risks were unreachable
URLs, duplicate/conflicting frames, accidental identity initialization and
connector-wide styling; focused URL, browser, real-HTTP endpoint and constructor
tests cover these. Production proof and deployment mapping remain explicit gaps.

Validation:

- `mix precommit`: **123 tests, 0 failures**, formatting/compilation/Credo clean.
  Includes an isolated dependency VM with a real ephemeral HTTP listener; the
  generated embed URL and a real runtime's iframe URL both return 200, without a
  package Repo/demo. Log: `/tmp/widget-m1a-precommit.log`.
- `npm --prefix assets run build`: successful TypeScript and both Vite bundles.
  Log: `/tmp/widget-m1a-assets.log`.
- Embed browser suite: **4 passed** using installed Chrome via
  `PLAYWRIGHT_CHROMIUM_BIN`. Covers single-script creation, no invented identity,
  duplicate inclusion, disposal/remount, invalid IDs/conflicting frames, and the
  existing manual API before/after iframe readiness. These are mock-host browser
  tests, not authenticated ZAQ chat. Log: `/tmp/widget-m1a-browser.log`.
- Actual shared constructors: **1 test, 0 failures**, now including stylesheet
  validation. Log: `/tmp/widget-m1a-constructors.log`.
- Actual configured host runtime lifecycle: **1 test, 0 failures**, including
  adapter availability and snippet generation. Log: `/tmp/widget-m1a-runtime.log`.
- Actual BO + actual package builder: **1 test, 0 failures**. Creates a disabled
  connector, sets exact origins and an agent route, generates a key, enables,
  copies escaped markup, changes settings, rotates, disables and re-enables.
  All records/global-base-URL changes roll back in ZAQ's test sandbox; no real
  customer backend was provisioned. Run from ZAQ:

  ```sh
  MIX_ENV=test mix run ../web_widget/test/support/integration/host_bo_smoke.exs
  ```

  Log: `/tmp/widget-m1a-bo.log`.
- Existing upstream runtime/contracts/conformance/Engine settings/BO tests:
  **3 properties, 44 tests, 0 failures**. Two BO tests assume the adapter is
  uninstalled; with our installed callback they initially failed those expected
  absence assertions. Use the package-owned runner to restore that baseline only
  within its test VM (never for real-package smokes):

  ```sh
  MIX_ENV=test mix run ../web_widget/test/support/integration/upstream_widget_baseline.exs \
    test/zaq/channels/web/runtime_test.exs \
    test/zaq/channels/web/contracts_test.exs \
    test/zaq/channels/web/widget_conformance_test.exs \
    test/zaq/engine/widget_connector_settings_test.exs \
    test/zaq_web/live/bo/communication/web_widget_live_test.exs
  ```

  No upstream assertions or files were edited. Log: `/tmp/widget-m1a-host-tests.log`.

## Milestone 2 — make first question, delivery and restoration work

- [x] Refactor `WidgetLive` state into verified session/readiness plus optional active conversation and active request. Opening the widget and typing a draft must create no history.
- [x] Consume the resolved connector key only in private adapter verification state. Choose a vetted assertion format with widget, sender, audience/issuer, expiry and replay protection; do not invent a host authentication command. Reject absent/placeholder keys. Rebuilds must invalidate old-key proofs and actively revoke affected connected sessions/subscriptions, including delivery, not merely reject their next dispatch. Keep the reject-all verifier until this is implemented and tested.
- [x] Original per-instance stylesheet initialization was implemented, then withdrawn by the signed-init follow-up above. Current init supports only the three signed application fields; no unsigned stylesheet params.
- [x] Verify the session, establish the private subscription, then dispatch the first question. Record the correlated creation receipt before processing queued live events. In the ordinary synchronous LiveView callback, PubSub messages queue while the sink returns; if dispatch is moved to a task, buffer events until acceptance is established.
- [x] Set the new conversation ID only from a matching accepted receipt. Refuse a second submission until the first has an established ID, and preserve the existing active-response send guard. A resumed acceptance with `created: false` must preserve the selected ID.
- [x] Normalize shared responses once, using semantic type plus the trusted event mapping. Check protocol version, request ID, transport message ID and accepted conversation before rendering. Widget ID and sender come from trusted session state, not response/browser claims.
- [x] Keep assistant transport IDs stable during streaming. Retain persisted message references separately for restoration; they are not interchangeable IDs.
- [x] Apply edit bodies as full replacement text. Stop typing before a terminal event, accept at most one terminal per active response and ignore late events from an old request/session.
- [x] Reconnect/resume re-verifies identity, reauthorizes the conversation and loads canonical history before sending again. Persist/return the accepted conversation ID through a defined parent resume mechanism; do not promise restoration across a full page reload from LiveView memory alone.

Response encoding into the current UI vocabulary:

| Shared response | Widget handling |
| --- | --- |
| `:widget_initialized` | Readiness with optional conversation ID; derive displayed user identity from verified session |
| `:conversation_created` | Correlated async receipt; set active conversation, not an assistant message |
| `:status` with `accepted: true` | Resumed async acceptance; retain conversation and active request |
| `:message_create/edit/complete` | `response.message.*`; map top-level `message_id` to payload `id`, public `body` to `content` |
| `:message_step` | Map public `step_id`, transport message ID and safe label; translate `:activity/:running` into widget `status/started` or `updated` for an existing step |
| `:message_failed` | Safe failure for the correlated transport message; normalize known public code/error into UI code and text, never expose raw internals |
| `:typing` | Correlated `response.typing` with boolean active state |
| `:error` | Correlated safe request error; preserve timeout `outcome: :unknown` rather than presenting it as guaranteed rejection |
| `:conversation_history` | Ordered public messages; normalize actual shared history IDs/roles/timestamps and preserve pagination positions outside rendered message data |

History defaults to 50 messages with a host maximum of 100. Use `after_position` / `up_to_position` for bounded retrieval; do not use conversation IDs as transcript cursors. A small first smoke transcript fits one page; test pagination before broader use. Unknown/foreign/deleted resume IDs fail without replacement creation. Timeout is an unknown outcome: never automatically retry or claim cancellation. If an initial timeout yields no conversation ID, show an unresolved outcome; do not invent an ID or pretend history recovery is possible without one.

Execution record (2026-10-05): `Integration.SignedIdentity` now uses HS256 JWT
with widget/sender/issuer/audience/issue-time/expiry/token-ID claims, configured explicitly with
`:connector_key`. The replay guard is node-local and volatile; it survives
connector replacement but is not a distributed/durable replay service. The
reject-all verifier remains available and existing ZAQ configuration is unchanged.
See [signed bootstrap setup](../authenticated-chat.md).

`Integration.Chat` owns the verified session, optional conversation, pending
request, transport correlation and history positions. WidgetLive subscribes before
admission, consumes semantic replies once, monitors runtime generation/expiry and
removes subscriptions on revocation. It preserves prompt context until acceptance,
keeps persisted references separate, blocks unknown-outcome retries and rejects
late/foreign events. Browser bootstrap accepts `identity_token`; the client emits
`zaq:conversation` for parent-owned resume storage and
`zaq:authentication-required` for obtaining a fresh proof on a new connection.
The later signed-init follow-up removes per-instance stylesheet parameters.

The selected first smoke restores 50 canonical messages. Pagination UI and
multi-node/durable replay storage remain broader deployment work. Legacy standalone
demo consumers retain their existing callback API; a new shared-protocol fixture
exercises the production path without adding a reverse dependency on ZAQ.

Validation: `mix precommit` passed **141 tests**, formatting, strict Credo and
compilation. TypeScript/Vite builds passed. The full Chromium suite passed
**61 tests**; after the final reconnect-notification guard, all **5** affected
embedding/authentication browser tests passed again. The actual ZAQ constructor
smoke passed **2 tests** against sibling revision `c38e7e4e5`.
Logs: `/tmp/m2-precommit.log`, `/tmp/m2-build.log`, `/tmp/m2-all-browser.log`,
`/tmp/m2-final-browser.log`, `/tmp/m2-shared.log`.
No ZAQ or test-widget source/configuration was changed in this milestone. Real
agent/model acceptance is still milestone 3 and requires host/backend setup.

Exit: fresh question, resumed question, streaming, terminal failure and known-ID
history recovery work through the shared boundary in deterministic fixtures.

## Milestone 3 — deterministic smoke using the real package

Add a package-owned smoke harness under `test/support/integration/` and execute it from the configured ZAQ host, without adding or editing ZAQ tests. Reuse setup patterns from `widget_conformance_test.exs` (real dispatch, connector/agent routing and `Zaq.TestSupport.OpenAIStub`), but install the actual package runtime builder and use its ingress/response encoding. Do not substitute the existing `AdapterFixture` for the implementation under test.

A server-only test verifier may resolve a fixed external subject here. It must be injected only in the isolated test configuration; this does not establish browser authentication acceptance.

Test sequence:

1. Enable a `web_widget` connector with an exact test parent origin. Start it through the existing channel lifecycle; fetch its actual package runtime by the string configuration ID.
2. Establish a verified test session and private subscription through the package. Submit readiness and assert nil conversation ID, `created: false`, and no new conversation/history relative to the pre-test baseline.
3. Submit `Say hello` asynchronously with parent context `Parent application context`. Assert an accepted creation receipt with a nonblank ID.
4. Observe the actual package-consumed stream: typing on → assistant create → optional edits/steps → typing off → exactly one live terminal. Assert final rendered event content `Widget answer`, stable transport ID and request correlation. Do not require optional events to occur in every run.
5. Request history through the package/shared command and assert the ordered context, question and answer. Submit a second question with the accepted ID and assert no second conversation or repeated seed context.
6. Use another verified sender and another connector to attempt resume/history and assert denial. Send malformed resume IDs and assert no fresh chat.
7. Disable the connector and assert runtime teardown. Re-enable/restart and restore authorized history without replaying the question.

After adding that test:

```sh
cd ../zaq
MIX_ENV=test mix run ../web_widget/test/support/integration/widget_package_smoke.exs
```

This is the first integration smoke target to implement. It needs no paid/live model request and isolates protocol/runtime faults before endpoint work. It is not a substitute for the browser smoke below.

## Milestone 4 — real iframe smoke in ZAQ

### Package endpoint and assets

- [ ] Implement/configure the package-owned endpoint chosen in milestone 1a. Separate its startup from `standalone_children/0`, which currently also starts a Repo and optional demo components. Start shared endpoint infrastructure once, not once per connector; preserve connector-owned runtime teardown. ZAQ changes stay limited to dependency/application configuration.
- [ ] Serve the package router, static assets and LiveView session pipeline from that endpoint. Keep BO login/actor requirements out of widget initialization. Verify the copied snippet resolves to this endpoint; if using the global ZAQ origin, supply an explicit deployment proxy mapping through configuration rather than editing ZAQ modules.
- [ ] Confirm `/live` session options and origin behavior through the actual iframe. Allowed parent origins govern embedding/postMessage; its LiveView socket connects to the widget endpoint origin. Do not disable socket origin checks globally.
- [ ] Build the package iframe and embed bundles, and include `web_widget/priv/static/assets` in the host release. Follow [host asset instructions](../host-integration.md), checking the actual path-dependency layout and matching host-resolved JS packages before changing any `deps` symlink.

Typical build steps, after dependency installation/configuration:

```sh
# From ../zaq:
mix deps.get
npm --prefix ../web_widget/assets ci
npm --prefix ../web_widget/assets run build
mix compile
```

### Minimal authenticated parent fixture

- [ ] Extend parent client/bootstrap handling to carry a scoped, expiring identity proof to the server verifier. Bind verified sender, widget/configuration and session lifetime before constructing Context. Reject proof/claimed-user disagreement.
- [ ] For the local browser smoke, serve a development-only parent page whose backend uses a known fixture session to issue a scoped proof. Keep signing credentials server-side and the issuer unavailable in production. Do not expose an arbitrary `user_id` → token endpoint or a trust-browser-ID shortcut.
- [ ] Use a configured second origin for the parent, for example `http://localhost:4010`, and embed the package's actual `/widget/<connector-id>` URL from the copied snippet. Add that exact parent origin to `allowed_domains`. Choose available endpoint ports through configuration.
- [ ] The verifier's concrete signing format/key distribution must be decided with the parent application before production acceptance. Reuse existing auth facilities where suitable; the adapter interface need not depend on one token format.

### Manual smoke procedure

1. Start ZAQ with its normal database/roles, enabled widget connector, configured agent route and the package builder. Start the local parent fixture. Initially use the deterministic host fixture if available; repeat once with a configured real agent/model for operational acceptance.
2. Open the parent page. Confirm iframe JS/CSS/chunks and `/web_widget/assets/embed.js` return successfully, the widget is framed, and its existing LiveView connection succeeds. No BO login redirect and no second realtime transport.
3. Complete verified initialization. Confirm the launcher opens without a persisted empty chat. Send `Say hello`; observe pending state and one completed assistant response. Record connector, request and conversation IDs without credentials.
4. Send another question and confirm the conversation ID is unchanged. Reload the iframe using the accepted ID via the resume mechanism; confirm ordered persisted history and no duplicate question/context. A full parent reload must explicitly supply the saved authorized ID if restoration is expected.
5. Test one denied origin, missing/expired/replayed proof, another sender's conversation and a disabled connector. Rotate the key through BO, provision the replacement to the parent backend, and verify old assertions and existing affected sessions are revoked. A pending runtime-sync warning must remain unresolved until reconciliation succeeds. Confirm no chat/history disclosure; missing/empty origin allowlists deny embedding. Check connected-session revocation as well as a fresh mount.

Pass means the real parent → iframe → LiveView → package → ZAQ → PubSub → LiveView → assistant-ui path works, and history comes from ZAQ persistence. Save failures by stage (assets, auth, readiness, admission, delivery or history) so they are diagnosable.

## Follow-up validation and acceptance

Add focused tests alongside each milestone in the existing runtime, protocol, adapter and `WidgetLive` suites. Cover nil-ID readiness, first-message receipt, immediate queued responses, semantic errors, subscription ownership, stale requests, full-text replacement, safe steps, transport versus persisted IDs, timeout without retry and malformed resume denial. Use real shared constructors in the ZAQ package tests rather than only hand-built widget maps.

Before wider use, add browser coverage for credential expiry/renewal/reconnect, foreign source/origin messages, endpoint restart, connector changes/revocation, history pagination and cleanup of subscriptions after session loss. Current mounted widget views are not automatically revoked by runtime changes; explicitly close that gap for this integration. Keep runtime-disabled and identity-expired sessions from displaying new responses or sending work.

The existing `assets/playwright.config.ts` starts mock-host servers; running it unchanged does not prove ZAQ integration. Add a distinct ZAQ-backed browser fixture/configuration while retaining the existing widget regression suite. Run relevant existing host runtime/request-owner/conversation tests and follow each repository's validation workflow once code changes land.

Deferred beyond the first smoke: multi-conversation list/sidebar integration (requires a supported host listing contract), inbound user editing (host rejects it), production parent identity enrollment/key management, deployment across separate role nodes and production release pinning. Security checks for any environment exposed to real users are prerequisites to that exposure, not optional follow-up work.

## Suggested implementation order

1. Contract alignment and existing host baseline.
2. Milestone 1a is complete. Next: milestone 2 identity/lazy-conversation/correlated delivery changes.
3. Real-package deterministic smoke and its negative cases.
4. Package endpoint/assets + verified parent fixture + iframe smoke, using the BO-generated installation snippet.
5. Reconnect, revocation and broader acceptance; then release pinning.

No Engine routing/persistence rewrite is planned: reuse the published config-bound ingress, existing channel lifecycle, shared constructors and canonical history operations. If implementation exposes a contract conflict, resolve it in the owning contract before adding a parallel integration path.
