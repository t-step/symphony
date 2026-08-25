# Implementation Plan: Local Work Tracking and Selectable Coding-Agent Execution for the Symphony Fork

**Branch**: `001-local-tracker-multi-agent` (Spec Kit feature identifier only; work stays on `development` per the fork's workflow) | **Date**: 2026-08-25 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-local-tracker-multi-agent/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

Add two additive, independently-configurable seams to the existing Symphony Elixir orchestrator without
touching scheduler, reconciliation, retry/backoff, or workspace-safety semantics:

1. A `"local"` (`SymphonyElixir.Tracker` behaviour) tracker adapter backed by a single durable,
   git-friendly JSON file the deployment owns, so a deployment can operate with zero hosted-tracker
   dependency. Lifecycle-state mutation reuses the existing agent-invoked, host-executed tracker-tool
   boundary (`agent_tool_specs/0` + `execute_agent_tool/3`) that GitHub/GitLab/Jira/Linear/Asana already
   use — no new orchestrator write API.
2. A new `SymphonyElixir.CodingAgent` behaviour, factored out of `Codex.AppServer`'s existing three-call
   shape (`start_session/2`, `run_turn/4`, `stop_session/1`), so `AgentRunner` dispatches to either the
   existing Codex integration (unchanged behavior, still the default) or a new Claude Code integration
   selected via a new `agent_execution.kind` WORKFLOW.md field. Claude Code drives the `claude` CLI
   headlessly per run and exposes tracker tools to it over a short-lived local stdio MCP server instead
   of Codex's proprietary `dynamicTools`/`item/tool/call` channel — the protocol difference stays fully
   inside the Claude Code integration module.

Both selections (`tracker.kind`, `agent_execution.kind`) are structural deployment configuration per
IV-005: read once at process start, not hot-reloaded, consistent with how `WorkflowStore` already has no
per-field dynamic/structural split and `Config.server_port/0` already treats one resource-bound setting
as restart-only precedent.

## Technical Context

**Language/Version**: Elixir `~> 1.19` (OTP 28), via `mise` — unchanged.

**Primary Dependencies**: No new runtime dependencies. Reuses `jason` (already a dependency) for the
local tracker's JSON durable store; reuses `Port`/stdio subprocess handling already used by
`Codex.AppServer` and `SymphonyElixir.SSH` for the Claude Code CLI subprocess and its companion stdio
MCP server. No SQL/Ecto-repo storage is introduced (Ecto here is embedded-schema config validation only,
not a database connection).

**Storage**: Local work-tracking source: one durable JSON file (default path resolved relative to the
selected `WORKFLOW.md`, mirroring `workspace.root` resolution), written via write-temp-file +
atomic rename. No database.

**Testing**: ExUnit via `mix test` / `make all` (format check, `mix specs.check`, `credo --strict`,
coverage at the existing 100% threshold in `mix.exs`, dialyzer) — unchanged toolchain; both new adapters
must clear the same gates, and `SymphonyElixir.Tracker.Memory` remains the pattern for adapter test
doubles.

**Target Platform**: Existing Burrito-packaged single-binary targets — `macos_arm64`, `macos_x86_64`,
`linux_arm64`, `linux_x86_64` — unchanged; both new integrations run as local subprocesses/files, no new
target platform requirements.

**Project Type**: Single Elixir OTP application (escript CLI + optional embedded Phoenix/Bandit
observability web server) — unchanged. New code lands as additional modules under
`lib/symphony_elixir/` alongside the existing tracker adapters and `codex/` integration, not a new
project or subsystem.

**Performance Goals**: No new performance goals; inherited invariants (IV-001/IV-002/IV-004) require the
local tracker and Claude Code paths to produce the same scheduler/retry/reconciliation decisions and
timing class as the existing hosted-tracker/Codex path, not a specific new throughput/latency target.

**Constraints**: Offline-capable for the local-tracker path (FR-004): no hosted tracker or hosted
control-plane network dependency; model-provider network access (Claude's own backend) is explicitly
out of scope for that constraint per the spec's Assumptions. Credential/tooling isolation between
integrations (FR-009) is a hard constraint, not a goal.

**Scale/Scope**: Two new adapters behind two existing pluggable boundaries (`Tracker`, and the new
`CodingAgent` behaviour extracted from `Codex.AppServer`'s shape); no change to the number or shape of
orchestrator-facing entities beyond what FR-001–FR-013 require.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Checked against `.specify/memory/constitution.md` v1.0.0:

- **I. Inherit Upstream First** — PASS. Both additions are adapters/implementations behind Symphony's
  existing `Tracker` behaviour and a `CodingAgent` behaviour distilled from `Codex.AppServer`'s already-existing
  public call shape, not new machinery. The one seam change (extracting `CodingAgent` as a named
  behaviour) formalizes an interface `AgentRunner` already relies on implicitly; it does not alter
  `Codex.AppServer`'s behavior.
- **II. Minimize Fork Delta** — PASS. No renames of the ~74 existing `codex_*`-prefixed runtime/telemetry
  field names across `orchestrator.ex` / `status_dashboard.ex` / `presenter.ex`; the Claude Code
  integration populates the same shared fields (justified below under IV-004 in data-model.md) instead
  of forcing a rename sweep. Local tracker reuses the existing optional `agent_tool_specs/2` +
  `execute_agent_tool/3` tracker-tool boundary instead of adding orchestrator write APIs.
- **III. Preserve Upstream Compatibility** — PASS. Existing Codex + hosted-tracker deployments require
  zero config changes (FR-006, SC-003); the new fields (`tracker.kind: local`, `agent_execution.kind:
  claude_code`) are additive and default-absent, matching upstream's own additive-adapter pattern (see
  `SPEC.md` §11 tracker adapter contract, which this plan does not modify).
- **IV. Specification Before Implementation** — PASS. This plan is reconciled against the frozen,
  reviewed `spec.md`; no requirement is reopened here (see Phase 0 decisions log for every design choice
  and which FR/IV/SC it satisfies).
- **V. Avoid Unnecessary Abstraction** — PASS. Local tracker storage is a single JSON file (no SQL
  engine, no ORM/repo layer, no new dependency) — the smallest concrete mechanism that satisfies FR-001,
  FR-004, and FR-013's corruption-vs-first-init distinction. `CodingAgent` is a 3-callback behaviour
  matching `Codex.AppServer`'s existing public shape exactly, not a generic multi-provider plugin
  framework (explicitly out of scope per spec's Non-Goals).
- **VI. Preserve Execution Boundaries** — PASS. Claude Code's MCP-based tool protocol and CLI
  invocation mechanics stay entirely inside `SymphonyElixir.ClaudeCode.*`; `AgentRunner` and the
  orchestrator only ever see the 3 `CodingAgent` callbacks, mirroring how `Codex.AppServer`'s JSON-RPC
  details never leak past `AgentRunner` today.
- **VII. Verify Fork Behavior Without Regressing Upstream** — PASS (verification plan, not evidence yet).
  `quickstart.md` defines the two independent-test scenarios from the spec (local tracker end-to-end,
  Claude Code end-to-end) plus the SC-004 equivalence check; `make all` remains the gate for
  upstream-inherited behavior.

No violations requiring the Complexity Tracking table.

### Post-Design Re-Check (after Phase 1)

Re-evaluated against `research.md`, `data-model.md`, and `contracts/*` as actually written:

- No new dependency was added (R1 confirmed JSON-file storage, no SQL/ORM). **I/V still PASS.**
- `CodingAgent` ended up as exactly the 3 callbacks `Codex.AppServer` already exposes (contracts/
  coding-agent-behaviour.md) — no growth beyond the extraction described pre-design. **I/VI still PASS.**
- The local tracker's one agent tool (`local_tracker_set_state`) reuses the existing optional
  `Tracker` callbacks with no orchestrator API change. **II/IV still PASS.**
- Two design details turned out to need explicit handling that were not obvious before Phase 0: (a)
  Claude Code's per-turn-process model (research.md R7) required `CodingAgent`'s contract to explicitly
  forbid assuming a live process after `start_session/2` and to allow `run_turn/4` to return an updated
  session for the next call — both captured in contracts/coding-agent-behaviour.md rather than requiring
  a workaround; (b) MCP tool exposure (R6) requires Symphony to generate a per-run MCP config file, which
  stays inside `ClaudeCode.MCPServer`/`ClaudeCode.DynamicTool` and never touches `Tracker` or
  `AgentRunner`. Neither required reopening the spec or the Constitution Check gates above.
- Three research decisions (R5, R7, R8) are explicitly flagged low-confidence on exact current CLI flag
  names/enum values and marked for re-verification against the installed Claude Code CLI version during
  implementation, per Principle IV ("Prior prototypes or exploratory implementations are evidence... not
  requirements") — this plan does not treat unverified flag names as settled fact, and implementation
  tasks must re-confirm them rather than trust this document verbatim.

No violations; Complexity Tracking table remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-local-tracker-multi-agent/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

Symphony is a single Elixir OTP application; this feature adds modules alongside the existing tracker
adapters and Codex integration rather than introducing a new project, app, or directory tree. Existing
files are shown only where they are the seam being extended.

```text
elixir/
├── lib/symphony_elixir/
│   ├── tracker.ex                  # EXISTING — @adapters map gains "local" => Local.Adapter
│   ├── tracker/
│   │   ├── issue.ex                # EXISTING — unchanged (normalized Issue struct)
│   │   ├── memory.ex                # EXISTING — unchanged (test-double adapter pattern)
│   │   └── ...
│   ├── local/                       # NEW — local work-tracking source
│   │   ├── adapter.ex               # @behaviour SymphonyElixir.Tracker
│   │   ├── store.ex                 # durable JSON file: load/init/write, corruption vs. first-use
│   │   └── agent_tool.ex            # agent_tool_specs/0 + execute_agent_tool/3 (lifecycle-state tool)
│   ├── coding_agent.ex              # NEW — behaviour: start_session/2, run_turn/4, stop_session/1
│   ├── agent_runner.ex              # EXISTING — resolves coding-agent module from Config instead of
│   │                                 #   hardcoding Codex.AppServer; turn-continuation loop unchanged
│   ├── codex/
│   │   ├── app_server.ex            # EXISTING — annotated @behaviour SymphonyElixir.CodingAgent,
│   │   │                             #   no functional change
│   │   └── dynamic_tool.ex          # EXISTING — unchanged
│   ├── claude_code/                 # NEW — Claude Code coding-agent execution integration
│   │   ├── app_server.ex            # @behaviour SymphonyElixir.CodingAgent; CLI subprocess + stream-json
│   │   ├── mcp_server.ex            # short-lived local stdio MCP server exposing tracker tools
│   │   └── dynamic_tool.ex          # dispatches MCP tool calls to Tracker.execute_bound_agent_tool/4
│   ├── config.ex                    # EXISTING — gains agent_execution.kind resolution
│   └── config/schema.ex             # EXISTING — gains `agent_execution` embed + `claude_code` embed
├── test/symphony_elixir/
│   ├── local_adapter_test.exs       # NEW — mirrors github_adapter_test.exs / jira_adapter_test.exs
│   ├── local_store_test.exs         # NEW — first-use init vs. corruption-surfaces-failure (FR-013)
│   ├── coding_agent_test.exs        # NEW — behaviour contract test shared by both integrations
│   ├── claude_code_app_server_test.exs   # NEW — mirrors app_server_test.exs
│   ├── claude_code_live_e2e_test.exs     # NEW — mirrors live_e2e_test.exs (flag-gated, real CLI)
│   └── agent_runner_dispatch_test.exs    # NEW — Config-selected integration routing, no cross-leak
└── AGENTS.md                        # updated if conventions change (Docs Update Policy)
```

**Structure Decision**: Extend the existing single-project Elixir layout in place. The local
work-tracking source is a new `SymphonyElixir.Tracker` adapter under `lib/symphony_elixir/local/`,
following the exact package shape of `github/`, `gitlab/`, `jira/`, `linear/`, `asana/` (an
`adapter.ex` implementing the behaviour, plus its own tool/storage modules) and registered the same way
in `Tracker.@adapters`. The Claude Code coding-agent execution integration is a new
`lib/symphony_elixir/claude_code/` package mirroring `lib/symphony_elixir/codex/`, implementing a newly
named `SymphonyElixir.CodingAgent` behaviour that `Codex.AppServer` is retrofitted to also implement
(structurally, with no behavior change) so `AgentRunner` can select either integration through
`Config` instead of importing `Codex.AppServer` directly. No new top-level app, no `tests/{contract,
integration,unit}` split — this codebase's existing convention is flat, subject-named files directly
under `test/symphony_elixir/`, which this plan follows.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
