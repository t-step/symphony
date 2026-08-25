# Project Map - symphony

Status: refined by AI session (2026-08-25).

## Project purpose
Symphony turns project work (tickets in an issue tracker) into isolated, autonomous coding-agent
implementation runs: it watches a tracker (Linear/GitHub/GitLab/Jira/Asana/local), spawns an
agent (e.g. Codex) per task in an isolated workspace, and lands the resulting PR once accepted —
so engineers manage work at a higher level instead of supervising agents turn-by-turn. The repo
root only hosts the spec (`SPEC.md`) and docs; the actual reference implementation lives entirely
under `elixir/` (an Elixir/OTP + Phoenix LiveView app).

## Stack
- Elixir ~> 1.19, Phoenix LiveView (dashboard UI), Mix project `symphony_elixir`.
- Tags: github-actions
- Detected from: .github/workflows, elixir/mix.exs

## Structure
- `SPEC.md` — the language-agnostic Symphony spec; canonical behavioral source of truth.
- `specs/001-local-tracker-multi-agent/` — Spec Kit feature: spec.md/plan.md/tasks.md for the
  local (file-backed) tracker adapter + multi-agent support currently being implemented.
- `docs/` — project documentation.
- `elixir/` — the reference implementation (all real code lives here).
  - `elixir/mix.exs` — Mix project definition; `test_coverage.ignore_modules` lists modules
    exempt from the 100% coverage gate (mostly I/O-boundary clients/adapters).
  - `elixir/WORKFLOW.md` — the live, user-editable config file (tracker.kind, agent settings)
    that `SymphonyElixir.Config` / `WorkflowStore` reload on a poll tick.
  - `elixir/lib/symphony_elixir/` — core app: config, orchestrator, agent runner, workspace.
    - `elixir/lib/symphony_elixir/config/` — `Config`/`Config.Schema` — parses WORKFLOW.md into
      structured settings; `finalize_settings/1` normalizes provider-specific fields (e.g. Linear
      secret env vars) based on `tracker.kind`.
    - `elixir/lib/symphony_elixir/tracker/` — `Tracker` behaviour/dispatch; `Tracker.adapter/0`
      pins the tracker adapter module from the structural (non-live-reloadable) `tracker.kind`.
    - `elixir/lib/symphony_elixir/linear/`, `github/`, `gitlab/`, `jira/`, `asana/` — per-provider
      tracker adapter + API client implementations.
    - `elixir/lib/symphony_elixir/codex/` — Codex agent process/app-server integration.
  - `elixir/lib/symphony_elixir_web/` — Phoenix LiveView status dashboard (`DashboardLive`,
    `ObservabilityApiController`).
  - `elixir/lib/mix/tasks/` — custom Mix tasks (CLI entry points).
  - `elixir/test/` — ExUnit test suite, mirrors `lib/` layout.

## Relationships
- `elixir/lib/symphony_elixir/config/` reads `elixir/WORKFLOW.md` and produces settings consumed
  by `elixir/lib/symphony_elixir/tracker/` and the orchestrator.
- `elixir/lib/symphony_elixir/tracker/` dispatches to one of `linear/`, `github/`, `gitlab/`,
  `jira/`, `asana/` (and, as of feature 001, a local file-backed tracker) based on `tracker.kind`.
- `elixir/lib/symphony_elixir_web/` (LiveView dashboard) reads orchestrator/tracker state to
  render live status; does not own persistence.
- `specs/001-local-tracker-multi-agent/` drives the local-tracker work landing under
  `elixir/lib/symphony_elixir/tracker/` and (per T004) a new `Local.Store` persistence module.

_Refined by an AI session; keep in sync as `specs/001-local-tracker-multi-agent/` lands._
