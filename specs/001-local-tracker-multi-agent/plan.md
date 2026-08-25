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
   use — no new orchestrator write API. The store must be explicitly provisioned once via a new
   `symphony local-tracker init` CLI operation before Symphony will start against it (research.md
   R2/R2a) — Symphony's own running process never auto-creates or self-heals the store, mirroring how no
   hosted tracker's underlying project/board is ever auto-created either.
2. A new `SymphonyElixir.CodingAgent` behaviour, factored out of `Codex.AppServer`'s existing three-call
   shape (`start_session/2`, `run_turn/4`, `stop_session/1`), so `AgentRunner` dispatches to either the
   existing Codex integration (unchanged behavior, still the default) or a new Claude Code integration
   selected via a new `agent_execution.kind` WORKFLOW.md field. Claude Code drives the `claude` CLI
   headlessly per turn (a fresh process per turn, resumed via a Symphony-generated `--session-id`
   captured once at session start) and exposes tracker tools to it over a per-run, in-BEAM HTTP MCP
   endpoint (hosted by Symphony itself via `Bandit`, already a dependency) instead of Codex's proprietary
   `dynamicTools`/`item/tool/call` channel — the protocol difference stays fully inside the Claude Code
   integration module, and no second OS process is ever spawned for tool exposure. Claude Code execution
   is local-only in this feature (`worker_host`/SSH remote execution stays fully supported, unchanged,
   for Codex — research.md R6a); this is a deliberate, validated scope boundary, not a silent gap.

Both selections (`tracker.kind`, `agent_execution.kind`) are structural deployment configuration per
IV-005: read once at process start, not hot-reloaded, consistent with how `WorkflowStore` already has no
per-field dynamic/structural split and `Config.server_port/0` already treats one resource-bound setting
as restart-only precedent. `tracker.provider.path` is a further, narrow structural exception specifically
when `tracker.kind: local` (research.md R9a) — a live change would switch the orchestrator to reading a
different local data source's identity mid-flight, a hazard no hosted tracker's `provider.*` fields share
(they only ever identify how to reach the same remote dataset); every other `tracker.provider.*` field,
for every other tracker kind, keeps today's dynamic-reload behavior unchanged.

## Technical Context

**Language/Version**: Elixir `~> 1.19` (OTP 28), via `mise` — unchanged.

**Primary Dependencies**: No new runtime dependencies. Reuses `jason` (already a dependency) for the
local tracker's JSON durable store; reuses `Port`/stdio subprocess handling already used by
`Codex.AppServer` and `SymphonyElixir.SSH` for the Claude Code CLI subprocess itself; reuses `Bandit`
(already a dependency, currently used only by the OPTIONAL observability HTTP extension per `SPEC.md`
§13.7) to host the Claude Code integration's MCP server as an in-BEAM HTTP endpoint instead of a second
OS process (research.md R6 — corrected during planning review from the original stdio-child-process
design, which had no working mechanism for a separately-spawned OS process to reach back into Symphony's
own BEAM VM). No SQL/Ecto-repo storage is introduced (Ecto here is embedded-schema config validation
only, not a database connection, though `Ecto.UUID.generate/0` is reused to generate Claude Code's
pre-assigned `--session-id`, research.md R7).

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
- **V. Avoid Unnecessary Abstraction** — PASS. Local tracker storage is a single JSON data file plus one
  small sibling establishment-marker file (no SQL engine, no ORM/repo layer, no new dependency) — the
  smallest concrete mechanism that satisfies FR-001, FR-004, and FR-013's fresh-vs-established-loss
  distinction across a restart, with access serialized through one `GenServer` (an existing, idiomatic
  in-codebase pattern, not a new abstraction) rather than a locking protocol. `CodingAgent` is a
  3-callback behaviour matching `Codex.AppServer`'s existing public shape exactly, not a generic
  multi-provider plugin framework (explicitly out of scope per spec's Non-Goals).
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

Re-evaluated against `research.md`, `data-model.md`, and `contracts/*` as actually written.

**Re-checked a second time after the planning-artifact correction pass** (human review identified 7 gaps
between the Phase 1 draft and the actual current implementation/CLI behavior; all 7 are now resolved in
`research.md` R1a, R2, R6, R7, R9a, R11, and R5/R8's confirmed-CLI-facts additions):

- No new dependency was added. `Bandit` (already a dependency, previously used only by the OPTIONAL
  observability extension) is now also reused for the Claude Code MCP endpoint (R6) instead of a second
  OS process; `Ecto.UUID.generate/0` (already available via the existing `ecto` dependency) generates
  Claude Code's session id (R7). **I/V still PASS** — no SQL/ORM, no distributed-Erlang setup, no new
  hex package.
- `CodingAgent` ended up as exactly the 3 callbacks `Codex.AppServer` already exposes, now verified
  against the actual current signatures rather than assumed (R4) — no growth beyond the extraction
  described pre-design, and the corrected contract (session identity fixed at `start_session/2`, `run_turn/4`
  never returns a new session) matches what `AgentRunner`'s loop has always actually done. **I/VI still
  PASS.**
- The local tracker's one agent tool (`local_tracker_set_state`) reuses the existing optional `Tracker`
  callbacks with no orchestrator API change; the new `Local.Store` GenServer (R1a) is purely an
  in-process serialization detail behind that same adapter, not a new orchestrator-facing surface.
  **II/IV still PASS.**
- Corrected during this pass (see research.md for full rationale on each): (a) FR-013's establishment
  signal needed a second, independently-durable marker file, not file-presence-alone (R2) — the review's
  identified restart-establishment gap; (b) Claude Code's tool exposure needed to be an in-BEAM HTTP MCP
  endpoint via the already-present `Bandit`, not a stdio child process with no path back into the BEAM
  (R6) — the review's identified process-boundary gap; (c) session identity is fixed once at
  `start_session/2` for both integrations (a pre-assigned `--session-id` for Claude Code, confirmed
  supported by the installed CLI), so `run_turn/4` never needs to return an updated session — the
  review's identified contract-coherence gap; (d) `tracker.provider.path` is structural, not dynamic,
  specifically for `tracker.kind: local` (R9a) — the review's identified live-reload hazard; (e)
  `dispatchable` is unconditionally `true` for the local tracker, matching the existing GitLab-adapter
  precedent, with no invented archived/withdrawn concept (R11) — the review's identified undefined-concept
  gap. None of these required reopening the frozen spec — every fix is a planning-level correction to
  research.md/data-model.md/contracts, not a new functional requirement.
- One further correction not driven by a specific numbered review item but surfaced while investigating
  it: concurrent `Task.Supervisor`-spawned attempts can genuinely race a local-tracker write, so R1's
  single-JSON-file choice needed R1a's `GenServer`-owned serialization to remain safe — re-evaluated per
  the review's Issue 6 prompt and re-affirmed (not replaced by SQLite): the actual complexity driver was
  serialization, which a GenServer solves at zero new-dependency cost, and which SQLite would still need
  regardless of storage format.
- Of the three research decisions originally flagged low-confidence (R5, R7, R8), two are now confirmed
  against the installed Claude Code CLI (v2.1.245) and current documentation rather than left as guesses:
  R5's `--verbose`-required-for-streaming claim and R8's `--permission-mode bypassPermissions` enum value
  and `ANTHROPIC_API_KEY`/`--bare` auth-isolation mechanism. Only R5's stream-json *event-type names*
  remain a genuine implementation-time verification item (no live turn was run during this planning
  pass), consistent with Principle IV's treatment of CLI protocol detail as implementation-time evidence,
  not settled fact.

No violations; Complexity Tracking table remains empty.

### Second Correction Pass Re-Check (planning-review round 2)

A second, tightly-scoped human review found the first correction pass's marker-with-self-heal FR-013
design still fragile, and found the Claude Code MCP topology under-specified for process ownership,
session/issue binding, authentication, and — critically — remote `worker_host` compatibility. Both are
now resolved (research.md R2/R2a, R6a); re-checked against the Constitution below.

- **FR-013 (R2/R2a)**: the design changed from "ordinary runtime code may write an establishment marker
  when it observes an ambiguous condition" to "ordinary runtime code never writes either file; one
  explicit, separately-invoked `symphony local-tracker init` operation is the only thing that ever does."
  **V (Avoid Unnecessary Abstraction) — still PASS, and more clearly so than before**: this removes a
  small implicit inference protocol from the hot path rather than adding one; the one real addition is a
  new CLI subcommand, which is a small, concrete, first-of-its-kind-but-narrow change to
  `CLI.evaluate/2`'s argument grammar — not a new orchestration framework, lifecycle ontology, or admin
  subsystem. Documented honestly as an addition, not hidden: this pass does add one genuinely new piece of
  CLI surface that did not exist before (§ below), and that is the correct, smallest-total-risk trade
  identified by directly re-evaluating the alternatives (research.md R2/R2a's Alternatives Considered).
- **Claude Code MCP topology, session binding, authentication (R6a)**: fully specified — one
  `ClaudeCode.MCPServer` per run (not per process/host/turn), process-local binding with no global lookup
  table, a per-run listener plus per-run unguessable token for isolation. **VI (Preserve Execution
  Boundaries) — still PASS**: the MCP wire protocol and binding-scoping mechanics stay entirely inside
  `ClaudeCode.*`; `Tracker.execute_bound_agent_tool/4` is called exactly as it always was, from a
  different (in-process) caller.
- **Remote `worker_host` for Claude Code**: scoped out of this feature entirely, rather than building a
  new remote-file-delivery mechanism or an SSH-forwarding bridge whose reliability Symphony cannot verify
  (research.md R6a). **V — still PASS, and this is the clearest instance in this feature of preferring the
  smallest total architecture over building speculative capability**: nothing in the frozen spec or
  upstream `SPEC.md` requires it, and the spec's own Assumptions explicitly permit Claude Code not
  exposing every Codex-specific capability. Existing Codex `worker_host` behavior is completely
  unmodified, and the restriction is enforced as a loud, operator-visible startup validation failure, not
  a silent behavior change (Principle VII's verification-before-done spirit — a clearly wrong config
  combination fails clearly instead of failing confusingly deep inside a live turn).
- **Honest accounting of what this pass adds, not just what it avoids**: one new CLI subcommand
  (`local-tracker init`), one new cross-field config validation rule (`claude_code` + `worker.ssh_hosts`),
  and two new tracker error categories (`local_tracker_not_initialized`, `local_tracker_ambiguous_state`).
  None of these individually or together rise to a Constitution violation requiring the Complexity
  Tracking table — each is a small, concrete, narrowly-scoped mechanism directly justified by a specific
  requirement (FR-013's distinction requirement; FR-009's isolation requirement composed with the
  confirmed absence of a safe remote-delivery mechanism) rather than general-purpose machinery adopted for
  its own sake. Per the review's own framing: "minimize fork delta" means minimizing total fork burden,
  not refusing every additional file/module — and the total burden here (one CLI branch, one validation
  rule, two error atoms) is smaller than either of the alternatives this pass rejected (a self-healing
  inference protocol; a speculative remote-MCP bridge).

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
│   │   ├── store.ex                 # GenServer: serializes all reads + the one lifecycle write
│   │   │                             #   (research.md R1a) against the data file + establishment marker;
│   │   │                             #   READ-ONLY with respect to establishment — never writes the data
│   │   │                             #   file's initial content or the marker (R2); returns
│   │   │                             #   not-initialized/ambiguous/corrupt per R2's decision table
│   │   └── agent_tool.ex            # agent_tool_specs/0 + execute_agent_tool/3 (lifecycle-state tool),
│   │                                 #   calls Local.Store via GenServer.call
│   ├── local/init.ex                # NEW — the ONLY code path that writes the data file's initial
│   │                                 #   content or the establishment marker (research.md R2a); invoked
│   │                                 #   by CLI.evaluate/2's new `local-tracker init` subcommand, not by
│   │                                 #   any part of the running orchestrator
│   ├── coding_agent.ex              # NEW — behaviour: start_session/2, run_turn/4, stop_session/1;
│   │                                 #   session identity fixed at start_session/2, never replaced by
│   │                                 #   run_turn/4 (research.md R7)
│   ├── agent_runner.ex              # EXISTING — resolves coding-agent module from Config instead of
│   │                                 #   hardcoding Codex.AppServer; turn-continuation loop unchanged
│   │                                 #   (already reuses the original start_session/2 result for every
│   │                                 #   turn today — agent_runner.ex:117-126 — now the documented
│   │                                 #   contract, not incidental)
│   ├── codex/
│   │   ├── app_server.ex            # EXISTING — annotated @behaviour SymphonyElixir.CodingAgent,
│   │   │                             #   no functional change
│   │   └── dynamic_tool.ex          # EXISTING — unchanged
│   ├── claude_code/                 # NEW — Claude Code coding-agent execution integration (local
│   │   │                             #   execution only — rejects worker_host, research.md R6a)
│   │   ├── app_server.ex            # @behaviour SymphonyElixir.CodingAgent; generates the run's
│   │   │                             #   session UUID in start_session/2 (Ecto.UUID.generate/0), starts
│   │   │                             #   one MCPServer for the run, rejects non-nil worker_host, launches
│   │   │                             #   `claude -p` fresh per turn via local Port + stream-json
│   │   └── mcp_server.ex            # One instance per run (started/owned by app_server.ex's
│   │                                 #   start_session/2, stopped in stop_session/1, dies with the run's
│   │                                 #   process on abnormal exit via ordinary OTP linking). Bandit HTTP
│   │                                 #   listener bound to 127.0.0.1:0; its own process state holds this
│   │                                 #   run's Tracker.bind_agent_tools/0 binding + current issue,
│   │                                 #   captured once — no lookup table, no shared/global state
│   │                                 #   (research.md R6a). Checks a per-run random bearer token on every
│   │                                 #   request, then calls Tracker.execute_bound_agent_tool/4 in-process
│   │                                 #   — no separate `dynamic_tool.ex` module needed since the handler
│   │                                 #   dispatches directly, there is no second OS process whose calls
│   │                                 #   need routing
│   ├── cli.ex                       # EXISTING — CLI.evaluate/2 gains a `local-tracker init
│   │                                 #   [path-to-WORKFLOW.md] [--reset]` leading subcommand (research.md
│   │                                 #   R2a) calling local/init.ex; every existing invocation shape is
│   │                                 #   unaffected
│   ├── config.ex                    # EXISTING — gains agent_execution.kind resolution + a new
│   │                                 #   cross-field validation rejecting agent_execution.kind:
│   │                                 #   claude_code combined with a non-empty worker.ssh_hosts (R6a)
│   └── config/schema.ex             # EXISTING — gains `agent_execution` embed + `claude_code` embed
├── test/symphony_elixir/
│   ├── local_adapter_test.exs       # NEW — mirrors github_adapter_test.exs / jira_adapter_test.exs;
│   │                                 #   includes dispatchable: true unconditionally (research.md R11)
│   ├── local_store_test.exs         # NEW — R2's read-only decision table (not-initialized/ambiguous/
│   │                                 #   established/established-loss/corrupt) asserting Local.Store
│   │                                 #   NEVER writes either file on any read path, plus concurrent-writer
│   │                                 #   serialization for the one lifecycle write (R1a: two simulated
│   │                                 #   concurrent callers, no lost update)
│   ├── local_init_test.exs          # NEW — local/init.ex's atomic two-file creation, idempotent re-run
│   │                                 #   over already-valid data (completes by writing only the marker),
│   │                                 #   refusal without --reset when already established, --reset
│   │                                 #   delete-then-recreate (research.md R2a)
│   ├── cli_local_tracker_init_test.exs   # NEW — CLI.evaluate/2's new subcommand branch: argument
│   │                                       #   parsing, delegates to local/init.ex, every existing
│   │                                       #   (non-`local-tracker`) invocation shape unaffected
│   ├── coding_agent_test.exs        # NEW — behaviour contract test shared by both integrations;
│   │                                 #   asserts session identity is unchanged across a multi-turn run
│   ├── claude_code_app_server_test.exs   # NEW — mirrors app_server_test.exs; asserts start_session/2
│   │                                       #   returns {:error, :remote_worker_not_supported} for a
│   │                                       #   non-nil worker_host (research.md R6a)
│   ├── claude_code_mcp_server_test.exs   # NEW — HTTP MCP handler dispatches to
│   │                                       #   Tracker.execute_bound_agent_tool/4; per-run token
│   │                                       #   rejects a wrong/missing token; two concurrently-started
│   │                                       #   MCPServer instances cannot reach each other's binding
│   │                                       #   (research.md R6a)
│   ├── claude_code_live_e2e_test.exs     # NEW — mirrors live_e2e_test.exs (flag-gated, real CLI)
│   ├── config_claude_code_worker_host_validation_test.exs   # NEW — agent_execution.kind: claude_code
│   │                                       #   combined with non-empty worker.ssh_hosts fails config
│   │                                       #   validation; worker.ssh_hosts alone (codex, default) is
│   │                                       #   unaffected (research.md R6a)
│   └── agent_runner_dispatch_test.exs    # NEW — Config-selected integration routing, no cross-leak
└── AGENTS.md                        # updated if conventions change (Docs Update Policy)
```

**Structure Decision**: Extend the existing single-project Elixir layout in place. The local
work-tracking source is a new `SymphonyElixir.Tracker` adapter under `lib/symphony_elixir/local/`,
following the exact package shape of `github/`, `gitlab/`, `jira/`, `linear/`, `asana/` (an
`adapter.ex` implementing the behaviour, plus its own tool/storage modules) and registered the same way
in `Tracker.@adapters`. `local/init.ex` is deliberately a separate module from `local/store.ex` within
that same package — not a new package or app — so the one code path that writes establishment state is
structurally distinct from, and never called by, the GenServer that only ever reads it (research.md R2).
The Claude Code coding-agent execution integration is a new `lib/symphony_elixir/claude_code/` package
mirroring `lib/symphony_elixir/codex/`, implementing a newly named `SymphonyElixir.CodingAgent` behaviour
that `Codex.AppServer` is retrofitted to also implement (structurally, with no behavior change) so
`AgentRunner` can select either integration through `Config` instead of importing `Codex.AppServer`
directly. `CLI.evaluate/2`'s new `local-tracker init` subcommand is the one genuinely new top-level entry
point this feature adds — it lives in the existing `cli.ex`, not a new escript/Burrito target, since the
packaged binary has exactly one entrypoint today and this is additive to its argument grammar, not a
second binary. No new top-level app, no `tests/{contract, integration, unit}` split — this codebase's
existing convention is flat, subject-named files directly under `test/symphony_elixir/`, which this plan
follows.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
