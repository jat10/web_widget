# Commands
- mix setup: fetch dependencies, initialize database, install npm dependencies and build assets.
- mix phx.server or iex -S mix phx.server: standalone development; /widget-demo embeds /widget/demo.
- mix assets.build: compile, TypeScript check and Vite bundle. Widget iframe uses built assets even in development, so rebuild UI changes.
- MIX_ENV=prod mix assets.deploy: build and digest assets.
- mix test [test/path_test.exs]: ExUnit with database create/migrate alias.
- mix precommit: test-environment compile with warnings as errors, unlock unused deps, format, test. This command can modify files.
- npm --prefix assets run test:e2e: Playwright; install Chromium via cd assets && npx playwright install chromium if needed. PLAYWRIGHT_CHROMIUM_BIN supports an existing browser.
- serena memories check: validate memory references from project root.
