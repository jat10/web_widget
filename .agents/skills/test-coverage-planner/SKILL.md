---
name: test-coverage-planner
description: Plan for test scenarios for uncovered code lines
license: MIT
metadata:
  audience: maintainers
  workflow: github
---

## What I do

I receive a filename with the line numbers that are not covered by a test

- Analyse the code at the uncovered lines for the file in the current project
- Generate one detailed plan to add tests to cover the gaps for each file

## How I do it

Before planning, read `AGENTS.md` and `docs/elixir-guidlines.md`. For runtime,
iframe, or event behavior, also read `docs/adapter-contract.md`. Inspect existing
ExUnit and browser tests before choosing where a scenario belongs.

Step 1: Read the code in the actual file for the uncovered lines
Step 2: Write a detailed plan to develop test scenarios that would cover the missing lines for the target file
Step 3: Report the plan with the test file to add/edit, the detailed scenario and branches that will be covered, the helpers that will be reused and the mocks to produce when applicable

When producing test scenarios plan:

- Prefer behavior-focused tests through public APIs and existing test helpers.
- Preserve the boundary: LiveView owns browser state; the host owns identity and persistence.
- Identify observable events that avoid sleeps, delays, and timing-dependent polling
- Explain any necessary global-state mutation and place those scenarios in isolated
  `async: false` test modules

## When to use me

Run when a file name with a list of line numbers for uncovered lines is provided
