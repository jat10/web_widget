# Toolchain
- mix.exs declares Elixir ~> 1.16, Phoenix ~> 1.8.3, LiveView ~> 1.1 and live_react ~> 2.0; resolve exact versions from mix.lock.
- assets/package.json uses React 19, assistant-ui, TypeScript, Vite 7 and Tailwind 4; npm lockfile is assets/package-lock.json.
- README requires Node 22.12+ or 24; Node 23 is unsupported by assistant-ui dependencies.
- npm Phoenix/LiveView/live_react packages reference ../deps; resolve Mix dependencies before npm ci. Host dependency builds need the dependency-path arrangement documented in README.
- Ecto/PostgreSQL setup is included in mix setup and mix test aliases; embedded host mode does not start the standalone Repo/endpoint by default.
