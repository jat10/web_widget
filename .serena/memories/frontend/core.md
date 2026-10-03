# Browser pointers
- assistant-ui integration uses @assistant-ui/react and useExternalStoreRuntime to adapt LiveView-owned messages into its runtime. Preserve this external-store boundary rather than introducing another canonical message list.
- WebWidget composes Conversation and FloatingComposer with assistant-ui runtime provider, thread, message and composer primitives; response steps are rendered by ResponseStep. Inspect assets/react-components/web-widget.tsx before changing this composition.
- assets/react-components/web-widget.tsx composes assistant-ui using LiveView props through live_react; canonical conversation ownership is described in README.md.
- assets/js/widget-context.ts handles parent bootstrap; assets/js/widget-demo.ts is the demo embedding listener, not a parent SDK.
- assets/css/widget.css holds widget customization variables; parent CSS cannot cross iframe boundary.
- assets/react-components/index.js registers components; assets/js/app.js is the browser entrypoint; assets/vite.config.js defines bundling.
- assets/tests/widget.spec.ts and host.spec.ts exercise real browser/LiveView flow; assets/playwright.config.ts configures servers.
