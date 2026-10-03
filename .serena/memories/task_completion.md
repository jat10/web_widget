# Validation
- Application changes: mix precommit (compile --warnings-as-errors, deps.unlock --unused, format, test in test environment).
- Frontend changes: mix assets.build (includes tsc), then npm --prefix assets run test:e2e for browser flow/layout changes.
- Playwright covers standalone port 4019 and minimal host endpoint port 4020; see assets/playwright.config.ts and test/support/host.
- For focused iteration: mix test path/to/relevant_test.exs. Database create/migrate are part of the test alias.
- Inspect resulting diff for formatter/dependency changes. Report checks not run and concrete blockers; setup-only Serena edits do not require application test execution.
