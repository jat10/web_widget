---
name: coverage-upper
description: Identify uncovered lines in changed Elixir files and add focused tests using ExCoveralls and mix coverup.
---

# Coverage Upper

Read `AGENTS.md` and task-relevant repository guidance before editing.
If the user supplies files and missed lines, begin with planning below.

## Discover gaps

1. Generate a fresh report with `mix coveralls.json` through Context Mode with
   a 600,000 ms execution timeout. Keep long-running tool work asynchronous so
   progress can be reported. If generation fails, report the blocker; do not use
   an older report. If Context Mode is unavailable, save logs and return bounded
   excerpts as directed by `AGENTS.md`.
2. Run `mix coverup [threshold] [limit]` (defaults: 95, 20). It reads
   `cover/excoveralls.json`; it does not run tests. It considers added/modified/
   renamed `lib/**/*.ex` files from `main...HEAD`, staged changes, and unstaged
   tracked changes. Untracked files and files absent from the report are not
   included. Ensure new target files are represented before interpreting an
   empty report as sufficient coverage. The command requires Git, jq, and a
   local `main` branch.
3. Use the printed one-based missed line numbers to inspect the current source.
   The percentage is for each whole file, not only changed lines. Confirm the
   report corresponds to the current source before planning.

## Plan and implement

Use [test-coverage-planner](../test-coverage-planner/SKILL.md) to produce a detailed
plan per file. Merge overlapping test-file plans, preserving scenarios, setup,
assertions, and covered branches. Use [test-gap-fixer](../test-gap-fixer/SKILL.md)
to implement each plan. Parallel delegation is optional when available; assign
non-overlapping test files to agents.

Do not change production behavior, lower thresholds, exclude files, or weaken
assertions to improve the report. Prefer observable synchronization over sleeps;
keep tests that mutate shared global state isolated.

## Validate and report

- Run the edited test files and `mix precommit` as required by this repository.
- Measure the targeted files with `mix coveralls.json path/to/edited_test.exs ...`.
  This replaces the JSON report with partial-suite coverage; label it accordingly
  and do not compare its total percentage with a full-suite report. Do not rerun
  the full suite solely to reassess coverage after the initial discovery run.
- Report tests added, checks run, remaining gaps, and whether targeted coverage
  improved. ExCoveralls measures Elixir code; use Playwright for browser behavior.
