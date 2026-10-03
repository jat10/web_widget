# Editing conventions
- AGENTS.md is the task dispatcher; read docs/elixir-guidlines.md before Elixir/Phoenix/OTP changes and docs/adapter-contract.md before integration, events, runtime or iframe changes.
- Resolve implementation/contract conflicts explicitly before changing integration behavior; keep these source documents authoritative rather than duplicating their rules in new docs.
- .formatter.exs imports Ecto/Phoenix and uses Phoenix.LiveView.HTMLFormatter for HEEx.
- React components belong in assets/react-components and are registered in index.js; inspect existing composition before UI edits.
- Add focused changed-behavior tests without weakening assertions. ExUnit lives in test; browser integration tests in assets/tests.
