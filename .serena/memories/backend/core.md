# Backend pointers
- Host mounting and static bundle/release instructions: README.md; integration decision source: docs/adapter-contract.md.
- lib/web_widget/runtime.ex owns widget runtime registration/configuration; lib/web_widget/router.ex and static.ex provide host mounting and assets.
- lib/web_widget/events.ex prepares inbound plain-map events; init.ex and message.ex hold internal payload representations. Do not infer actual dispatch from event construction.
- lib/web_widget_web/live/widget_live.ex owns browser conversation state; test/web_widget_web/live/widget_live_test.exs covers it.
- test/web_widget/dependency_host_test.exs, test/web_widget_web/host_router_test.exs and test/support/host cover dependency hosting.
