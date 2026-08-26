---

description: "Task list for Local Work Tracking and Selectable Coding-Agent Execution for the Symphony Fork"
---

# Tasks: Local Work Tracking and Selectable Coding-Agent Execution for the Symphony Fork

**Input**: Design documents from `/specs/001-local-tracker-multi-agent/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md), frozen at commit `17e7c57` on `development`.

**Tests**: Included alongside the implementation work they validate (not deferred to a final phase), per the reviewed planning artifacts and the project's `make all` gate (format check, `mix specs.check`, `credo --strict`, 100% coverage threshold, dialyzer).

**Organization**: Tasks are grouped by user story (spec.md priorities: US1 = P1, US2 = P1, US3 = P3) to enable independent implementation and testing of each story. All file paths are relative to `elixir/` unless stated otherwise.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1, US2, or US3 — omitted for Setup/Foundational/Polish tasks

---

## Phase 1: Setup

**Purpose**: Trivial, shared repo prep with no code dependencies.

- [x] T001 [P] Add `.symphony/local_tracker.json` and `.symphony/local_tracker.json.established` to `elixir/.gitignore` by literal path (not a blanket `.symphony/` ignore), matching the existing narrow `.codex/original-user-prompt.txt` precedent (data-model.md §1, research.md R2)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one piece of infrastructure both US1 and US2 need to satisfy IV-005's restart-only semantics. Everything else in this feature is genuinely additive/independent per plan.md ("two additive, independently-configurable seams") — there is no other shared blocking work.

**⚠️ CRITICAL**: Both user stories introduce a structural (restart-only) selector — `tracker.kind`/`tracker.provider.path` (US1) and `agent_execution.kind` (US2). `WorkflowStore.reload_state/1` currently reloads its entire settings struct wholesale on every `WORKFLOW.md` change with no per-field distinction (confirmed: `workflow_store.ex:122-155`; `Tracker.adapter/0` and `fetch_issues_by_states/1`/`fetch_issues_by_ids/1` read `Config.settings!().tracker` fresh on every call, `tracker.ex:33-41,87-91`). Without a capture-once mechanism, a live `WORKFLOW.md` edit to either selector would take effect on the very next dispatch tick instead of the next restart, violating IV-005/research.md R9/R9a. This phase implements that capture; the exact internal ownership (e.g., where the pinned values live) is an implementation-time decision the planning artifacts deliberately left open — see the final report's "remaining implementation uncertainty" note.

- [x] T002 Implement structural-configuration capture in `lib/symphony_elixir/config.ex`/`lib/symphony_elixir/workflow_store.ex` (with a call-site change in `lib/symphony_elixir/tracker.ex`) so that `tracker.kind` is read once at `WorkflowStore.init/1` (Symphony process start) and is NOT affected by a later `WorkflowStore` reload, while every other dynamically-reloaded setting continues to reload live exactly as today (IV-005; research.md R9). **Delivered now**: `WorkflowStore.State` gains a `:structural` field (`%{tracker_kind: ...}`) computed once in `init/1` and preserved verbatim across every later `reload_path/2`, exposed via `WorkflowStore.structural_settings/0`/`Config.structural_settings!/0`; `Tracker.adapter/0` (and therefore `Tracker.bind_agent_tools/0`) resolves the active adapter module from this pinned snapshot instead of a live `Config.settings!().tracker.kind` read. **Deferred to their prerequisite tasks, not built now** (would otherwise be untested/dead code — `"local"` is not yet a registered tracker adapter and `agent_execution.kind` does not yet exist as a schema field): `tracker.provider.path` pinning-when-local is added to this same `structural` map by T008 once `Local.Adapter` exists; `agent_execution.kind` is added by T025 once that schema field exists (per T025's own text, unchanged). **Guardrail followed**: no second configuration store, no provider/plugin registry, no new configuration subsystem — the mechanism is one new field on `WorkflowStore.State` (the existing settings owner) plus one accessor function, extended incrementally.
- [x] T003 Add `test/symphony_elixir/config_structural_snapshot_test.exs` asserting: a live `WORKFLOW.md` edit to `tracker.kind` does not change effective adapter resolution before a `WorkflowStore` restart; a non-`tracker.kind` dynamic field (tested via `tracker.api_key`/`codex.turn_timeout_ms`) still reloads live on every call, exactly as today; `structural_settings!/0`'s not-running fallback (mirroring `Config.settings!/0`'s existing fallback pattern) both succeeds and raises correctly. `agent_execution.kind` coverage is deferred to T025 alongside T002's corresponding extension, since that field does not exist yet (depends on T002)

**Checkpoint**: Structural-config capture exists. US1 and US2 can now proceed independently/in parallel.

---

## Phase 3: User Story 1 - Operate Symphony on Locally Tracked Work (Priority: P1) 🎯 MVP

**Goal**: A durable, git-friendly local JSON work-tracking source usable with zero hosted-tracker/control-plane dependency — explicitly initialized, never silently (re)created, with agent-invoked lifecycle writes and safe concurrent access.

**Independent Test**: Run `symphony local-tracker init`, seed one dispatch-eligible item in `.symphony/local_tracker.json`, start Symphony with `tracker.kind: local` and no hosted-tracker credentials configured, and observe poll → dispatch → execute → terminal lifecycle state (quickstart.md Scenario 1).

### Implementation & Tests for User Story 1

- [x] T004 [P] [US1] Implement `lib/symphony_elixir/local/store.ex` — named singleton `GenServer`, started only when `tracker.kind: local` is the active structural selection (T002). Its read path implements research.md R2's full decision table (both-absent → `local_tracker_not_initialized`; data-present/marker-absent → `local_tracker_ambiguous_state`/`marker_missing`; both valid → normal; marker-present/data-absent-or-invalid → `local_tracker_corrupt`) and **never writes** the data file's initial content or the marker under any circumstance. Also exposes the one ongoing lifecycle write (rewrite `issues[<id>].state` + `updated_at`, atomic write-temp+rename, idempotent no-op on same-value), serialized through the GenServer's mailbox so concurrent callers cannot race a read-modify-write cycle (data-model.md §1, research.md R1/R1a/R2)
- [x] T005 [P] [US1] Implement `lib/symphony_elixir/local/init.ex` — the *only* code path in this feature that writes the data file's initial content (`{"format_version": 1, "issues": {}}`) and the establishment marker (`{"established_at": "<RFC 3339>"}`), data file first then marker, via the same atomic write-temp+rename path as T004. Refuses to overwrite an already-established store unless `--reset` is passed; if the data file exists and parses validly but the marker is missing, completes establishment by writing only the marker (data file untouched); if the data file exists but does not parse, refuses with a clear error; `--reset` deletes both files (if present) and recreates fresh (research.md R2/R2a)
- [x] T006 [P] [US1] Add `test/symphony_elixir/local_store_test.exs` covering research.md R2's full read/open decision table end to end, plus concurrent-writer serialization: two simulated concurrent lifecycle-write calls against different issues both land with no lost update (quickstart.md Scenario 1 step 13) (depends on T004)
- [x] T007 [P] [US1] Add `test/symphony_elixir/local_init_test.exs` covering atomic two-file creation order, idempotent re-run over already-valid data (completes by writing only the marker; data file byte-for-byte unchanged), refusal without `--reset` when already established, refusal when the data file is present but unparseable, and `--reset` delete-then-recreate (depends on T005)
- [x] T008 [P] [US1] Implement `lib/symphony_elixir/local/adapter.ex` — `@behaviour SymphonyElixir.Tracker`; `fetch_issues_by_states/1`/`fetch_issues_by_ids/1` delegate to `Local.Store` (T004) and map each `IssueRecord` 1:1 onto `Tracker.Issue.t()`; `validate_config/1` checks the path's parent directory is writable and surfaces `local_tracker_not_initialized`/`local_tracker_ambiguous_state` from `Local.Store` if the store isn't yet established; `dispatchable` is always `true` (research.md R11, matching the `gitlab/client.ex:198` precedent); default `active_states` `["todo", "in_progress", "blocked"]` / `terminal_states` `["done", "cancelled"]`, overridable per `tracker.active_states`/`tracker.terminal_states`; `secret_environment_names/1` returns `[]`. Also extends T002's `WorkflowStore` structural-config snapshot (`compute_structural/1`) to add `tracker_provider_path` (pinned only when `tracker.kind: local`), since this is the point at which `"local"` first becomes a registered, validatable adapter and the pinning becomes testable end to end (depends on T004)
- [x] T009 [P] [US1] Implement `lib/symphony_elixir/local/agent_tool.ex` — `agent_tool_specs/0` + `execute_agent_tool/3` exposing one tool, `local_tracker_set_state` (input schema `{"state": string, required}`), scoped to the current session's bound issue via `Tracker.execute_bound_agent_tool/4`'s context (cannot target an arbitrary `id`), mutating only that issue's `state` through `Local.Store`'s lifecycle write (T004); idempotent no-op when setting to the current value; returns the same `%{"success" => bool, "output" => ..., "contentItems" => [...]}` shape `GitHub.AgentTool` already normalizes, with `success: false` and a structured error on write/IO failure (depends on T004)
- [x] T010 [US1] Register `"local" => SymphonyElixir.Local.Adapter` in the `@adapters` map in `lib/symphony_elixir/tracker.ex` (depends on T008)
- [x] T011 [US1] Add `test/symphony_elixir/local_adapter_test.exs`, mirroring `github_adapter_test.exs`/`gitlab_adapter_test.exs`: **startup/config-validation coverage** — `validate_config/1` fails with `local_tracker_not_initialized` when neither the data file nor the marker exists, and with `local_tracker_ambiguous_state` when the data file exists but the marker does not, both surfaced the same operator-visible startup/config-validation-failure way a missing hosted-tracker credential already is, before the scheduling loop ever starts (contracts/local-tracker-adapter.md `validate_config/1`); **normal-operation coverage** — a valid, established store's `validate_config/1` succeeds and reads delegate through `Local.Store`; advertises `local_tracker_set_state` and token env names `[]`; `dispatchable: true` unconditionally on every fetched record; the tool mutates only the bound issue's state and no other record; idempotency on same-value writes (depends on T008, T009, T010)
- [x] T012 [P] [US1] Add a `local-tracker init [path-to-WORKFLOW.md] [--reset]` leading-subcommand branch to `CLI.evaluate/2` in `lib/symphony_elixir/cli.ex` — parses the optional `WORKFLOW.md` path (default `./WORKFLOW.md`, matching the existing run-default resolution), loads it via the existing `Workflow.load/1` → `Schema.parse/1` path, delegates to `Local.Init` (T005), and does not start the orchestrator/scheduler. Every existing (non-`local-tracker`) invocation shape is completely unaffected (depends on T005)
- [x] T013 [US1] Add `test/symphony_elixir/cli_local_tracker_init_test.exs` covering argument parsing (default path, explicit path, `--reset`), delegation to `Local.Init`, and that every existing CLI invocation shape (e.g. `symphony run`, a bare `WORKFLOW.md` path) remains unaffected (depends on T012)
- [x] T014 [US1] Add a case to `test/symphony_elixir/orchestrator_status_test.exs` verifying the orchestrator's existing tracker/source-failure handling (FR-008.3: skip the affected poll tick or reconciliation pass, retry on the next one, leave already-running attempts undisturbed — `orchestrator.ex`'s `maybe_dispatch/1`/`reconcile_running_issues`/`reconcile_blocked_issues`) applies unchanged for `Local.Adapter` failures that can genuinely occur *after* successful startup: an established store's data file being deleted or otherwise becoming corrupt/unreadable mid-run (FR-013, `local_tracker_corrupt`), and a transient, self-resolving local source read/availability failure (tolerated the same way Symphony already tolerates a hosted-tracker outage). Assert: the affected poll/reconciliation pass is skipped and retried on the next tick; already-running attempts are left undisturbed; no individual work-item attempt is automatically failed merely because the source refresh failed; the established-state-loss case surfaces as `local_tracker_corrupt`, distinct from the transient case. Do NOT exercise `local_tracker_not_initialized` here — under this plan it is a startup/config-validation failure (`validate_config/1`, covered by T011) that gates a deployment out of ever reaching normal scheduling, so it is not a state ordinary post-start polling can encounter, and this test must not bend production behavior to make that state artificially injectable mid-run (depends on T008)
- [x] T015 [US1] Add a restart-only regression case for `tracker.provider.path` under `tracker.kind: local` to `test/symphony_elixir/config_structural_snapshot_test.exs` (T003): editing `tracker.provider.path` to a different, uninitialized path while Symphony is running does not change which store is read until restart (research.md R9a; quickstart.md Scenario 1 step 12) (depends on T003, T008)

**Checkpoint**: User Story 1 is independently functional — quickstart.md Scenario 1 (fresh-init refusal, first init, seed+dispatch+complete, normal restart, corruption/ambiguous-state/established-loss handling, deliberate `--reset`, restart-only path, concurrent lifecycle writes) passes end to end with zero hosted-tracker/Codex involvement.

---

## Phase 4: User Story 2 - Execute Work Through Claude Code (Priority: P1)

**Goal**: A second, selectable coding-agent execution integration (Claude Code) alongside an unmodified, still-default Codex integration, sharing the same run-attempt lifecycle, retry/backoff, and observability conventions.

**Independent Test**: Configure `agent_execution.kind: claude_code`, dispatch a work item, confirm it completes through the same run-attempt lifecycle phases as Codex, ending in a terminal state, while a separate unmodified Codex deployment is provably unaffected (quickstart.md Scenario 2).

### Implementation & Tests for User Story 2

- [x] T016 [P] [US2] Verify the installed Claude Code CLI against research.md R5/R7/R8's confidence-flagged items before implementing T022: confirm via `claude --help` (targeted CLI version) that `--session-id <uuid>` (turn 1) / `--resume <uuid>` (later turns), `--output-format stream-json --verbose --include-partial-messages`, `--permission-mode bypassPermissions`, `--bare`, and `--strict-mcp-config` all exist with the documented semantics; run one real `claude -p` turn to capture and document the actual stream-json event-type names (the one still-open low-confidence item from R5) that T022's turn-output parser must handle. Record findings as a dated addendum in `research.md` — no other planning artifact changes
- [x] T017 [P] [US2] Define the `SymphonyElixir.CodingAgent` behaviour in `lib/symphony_elixir/coding_agent.ex` per `contracts/coding-agent-behaviour.md`: `start_session(workspace, opts) :: {:ok, session} | {:error, reason}`, `run_turn(session, prompt, issue, opts) :: {:ok, turn_result} | {:error, reason}` (no session value in the return — session identity is fixed at `start_session/2` for the life of the run), `stop_session(session) :: :ok`
- [x] T018 [US2] Retrofit `lib/symphony_elixir/codex/app_server.ex` with `@behaviour SymphonyElixir.CodingAgent` — annotation only, zero functional change (depends on T017)
- [x] T019 [US2] Add `test/symphony_elixir/coding_agent_test.exs` asserting `Codex.AppServer` satisfies the `CodingAgent` behaviour, and confirm the existing `app_server_test.exs`, `dynamic_tool_test.exs`, and `live_e2e_test.exs` suites still pass unmodified after T018's retrofit (backward-compatibility regression gate for the extraction) (depends on T018)
- [x] T020 [P] [US2] Implement `lib/symphony_elixir/claude_code/mcp_server.ex` — one `Bandit` HTTP listener per coding-agent run, bound to `127.0.0.1:0`, started in `start_session/2` and stopped in `stop_session/1` (T022), reused across all of that run's turns; holds `Tracker.bind_agent_tools/0`'s binding and the current issue in its own process state (no lookup table, no global/shared state); checks a per-run cryptographically-random bearer token embedded in the request URL path before dispatching to `Tracker.execute_bound_agent_tool/4` in-process (research.md R6/R6a)
- [x] T021 [US2] Add `test/symphony_elixir/claude_code_mcp_server_test.exs`: a tool-call HTTP request dispatches to `Tracker.execute_bound_agent_tool/4` with the correct bound issue; a wrong or missing token is rejected; two concurrently-started `MCPServer` instances cannot reach each other's binding (a request to run A's port using run B's token, or vice versa, is rejected) (depends on T020)
- [x] T022 [US2] Implement `lib/symphony_elixir/claude_code/app_server.ex` — `@behaviour SymphonyElixir.CodingAgent`. `start_session/2`: generates the run's session UUID via `Ecto.UUID.generate/0`, returns `{:error, :remote_worker_not_supported}` for a non-nil `worker_host` (defense in depth), starts one `ClaudeCode.MCPServer` (T020) and writes the per-run `--mcp-config` JSON to a local temp path. `run_turn/4`: spawns `claude -p ... --session-id <uuid>` on turn 1 / `--resume <uuid>` on later turns via a local `Port.open/2` (cwd = the workspace path) with `--output-format stream-json --verbose --include-partial-messages --permission-mode bypassPermissions --bare --strict-mcp-config`; parses line-delimited stream-json events using T016's confirmed event names; emits `session_started`, a terminal per-turn outcome, and `startup_failed` via `on_message`; populates the existing `codex_*`-prefixed status-dashboard fields (data-model.md §5 — no rename) with this run's session/turn/token data; launch environment excludes `OPENAI_API_KEY`/Codex's auth file and passes only `ANTHROPIC_API_KEY`. `stop_session/1`: stops the MCP listener and tolerates it already being stopped or never having started (depends on T017, T020, T016)
- [x] T023 [US2] Add `test/symphony_elixir/claude_code_app_server_test.exs`: `start_session/2` returns `{:error, :remote_worker_not_supported}` for a non-nil `worker_host`; the session UUID is fixed across a simulated multi-turn run (passed as `--session-id` then `--resume`); launch environment excludes `OPENAI_API_KEY`; a missing/nonexistent `claude_code.command` executable surfaces as an `{:error, reason}` attempt failure, not a crash; `stop_session/1` is safe to call when `start_session/2` failed before the listener came up (depends on T022)
- [x] T024 [P] [US2] Add an `agent_execution` embed (`kind: "codex" | "claude_code"`, default `"codex"`) and a sibling `claude_code` embed (`command`, `turn_timeout_ms`, `read_timeout_ms`, mirroring the existing `codex` embed's shape) to `lib/symphony_elixir/config/schema.ex`
- [x] T025 [US2] Add cross-field validation to the `Config.validate_settings/1` pipeline in `lib/symphony_elixir/config.ex` rejecting `agent_execution.kind: claude_code` combined with a non-empty `worker.ssh_hosts` (clear startup-failure message, same class as every other config validation error); wire `agent_execution.kind` into T002's structural-config snapshot (depends on T024, T002)
- [x] T026 [US2] Add `test/symphony_elixir/config_claude_code_worker_host_validation_test.exs`: `agent_execution.kind: claude_code` with non-empty `worker.ssh_hosts` fails startup validation with a clear message; `worker.ssh_hosts` alone with `agent_execution.kind: codex` (default) is unaffected (depends on T025)
- [x] T027 [US2] Resolve the concrete `CodingAgent` module in `lib/symphony_elixir/agent_runner.ex` from T025's structural `agent_execution.kind` snapshot instead of hardcoding `Codex.AppServer`, leaving the turn-continuation loop's existing unconditional reuse of the original `start_session/2` result (`do_run_codex_turns/8`, `agent_runner.ex:117-126`) unchanged (depends on T025, T018, T022)
- [x] T028 [US2] Add `test/symphony_elixir/agent_runner_dispatch_test.exs`: a `codex`-configured run dispatches to `Codex.AppServer`; a `claude_code`-configured run dispatches to `ClaudeCode.AppServer`; no configuration or credential from the inactive integration is read or passed into the active integration's child process (FR-009) (depends on T027)
- [x] T028A [US2] **Repair task, inserted out-of-sequence** (research.md R8 Correction Addendum, 2026-08-26 — a planning correction discovered after T022/T023/T024 shipped, not known at the time those tasks were completed): change `claude_code.command`'s schema default (`config/schema.ex`) from `claude --bare --permission-mode bypassPermissions --strict-mcp-config` to `claude --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config`, so the default local execution model authenticates via the operator's existing Claude subscription/OAuth login and loads repository-scoped `CLAUDE.md`/hooks/settings while excluding user-global Claude Code configuration (contracts/workflow-config-fields.md's new "Local execution trust model" section). Update `ClaudeCode.AppServer` so `start_port/6` composes the workspace's own `.mcp.json` (when present at the workspace root) alongside Symphony's generated per-run MCP config under one `--mcp-config` invocation (`mcp_config_args/2`), computed once in `start_session/2` (`repo_mcp_config_path/1`) and never deleted by `stop_session/1` (only Symphony's own generated file is). `--strict-mcp-config`, `--permission-mode bypassPermissions`, the direct-executable/no-shell/whitespace-argv `claude_code.command` parsing model, and the `OPENAI_API_KEY`/Codex-credential environment allow-list are all unchanged. Config-only + `ClaudeCode.AppServer`-only change — no `CodingAgent` redesign, no new auth-mode abstraction, no provider-selection/scheduling change (depends on T022, T024)
- [x] T029 [US2] Add `test/symphony_elixir/claude_code_live_e2e_test.exs`, flag-gated (mirroring `live_e2e_test.exs`), running one real `claude_code`-backed work item through Symphony end to end and asserting it reaches a terminal succeeded state with the same class of operator-visible lifecycle observability a Codex run reports (SC-002) — must prove the *repaired* T028A local execution configuration, including subscription/OAuth auth, not `--bare`/`ANTHROPIC_API_KEY` (depends on T022, T027, T028A)
- [x] T030 [US2] Run the full existing hosted-tracker + Codex regression suite (`app_server_test.exs`, `dynamic_tool_test.exs`, `live_e2e_test.exs`, `orchestrator_status_test.exs`, `cli_test.exs`, adapter tests) and confirm zero behavioral change after T018/T027 (SC-003, FR-006) (depends on T027)

**Checkpoint**: User Story 2 is independently functional — quickstart.md Scenario 2 (Claude Code-only run, unaffected parallel Codex deployment, launch-failure retry, remote-worker rejection) passes.

---

## Phase 5: User Story 3 - Operate with Local Work Tracking and Claude Code Together (Priority: P3)

**Goal**: Confirm the two independently-required capabilities (US1, US2) compose as one ordinary supported deployment shape, with no new orchestration behavior of their own. No new production code — verification only.

**Independent Test**: Run a deployment configured with only `tracker.kind: local` and `agent_execution.kind: claude_code`; confirm a work item completes its full lifecycle using only those two components (quickstart.md Scenario 3).

### Tests for User Story 3

**Testing approach (deterministic, not live-model)**: T031–T034 exercise the real Symphony orchestration/integration boundaries (dispatch, workspace, MCP transport, `Local.Store`) but drive the Claude Code side through the same kind of deterministic fake-executable fixture `app_server_test.exs` already uses for Codex (`fake-codex`, e.g. a scripted `fake-claude` standing in for `claude_code.command`) — no real Claude CLI process, model call, network access, or API credential is required, and none of these tests may depend on an LLM actually following a natural-language instruction. This keeps them safe and non-flaky for ordinary `mix test`/`make all` runs. T029 remains the one flag-gated test that proves the real, installed Claude CLI/provider path end to end; this phase does not add a second live-E2E task.

- [x] T031 [US3] Add `test/symphony_elixir/local_tracker_claude_code_composition_test.exs` running one dispatch-eligible `tracker.kind: local` item through a `agent_execution.kind: claude_code` deployment end to end, driven by the deterministic fake-`claude` fixture described above (no hosted tracker, no Codex, no real model call), confirming full lifecycle completion (spec User Story 3 AS1; quickstart.md Scenario 3) (depends on T012, T022, T027)
- [x] T032 [US3] In the same file, using the same fixture, add a case confirming an MCP `local_tracker_set_state` tool call — issued by the fake-`claude` fixture's scripted turn, not by an LLM's own decision — from a `claude_code` run lands on `.symphony/local_tracker.json`'s exact bound issue record, verified by inspecting the file directly (quickstart.md Scenario 2 step 6; research.md R6a) (depends on T031)
- [x] T033 [US3] In the same file, using the same fixture, add a concurrency case proving cross-run MCP isolation mechanically rather than via model compliance: two concurrent `claude_code`-backed runs (`agent.max_concurrent_agents >= 2`) against two `tracker.kind: local` items, each run's fake-`claude` fixture *scripted* to call `local_tracker_set_state` against its own bound issue (not phrased as a natural-language instruction an LLM must correctly interpret); after both complete, confirm neither item's record shows the other's identifier/content, and additionally confirm — mirroring T021's unit-level check at full composition scope — that a request carrying run A's token against run B's port (or vice versa) is rejected (quickstart.md Scenario 2 step 7; research.md R6a's per-run isolation) (depends on T031)
- [x] T034 [US3] In the same file, using the same fixture with fixed, scripted per-turn outcomes (so timing and results are deterministic, not model-variable), add an SC-004 equivalence case comparing scheduler dispatch order, concurrency-limit enforcement, and retry/backoff decisions between a `tracker.kind: local` + `agent_execution.kind: claude_code` deployment and an existing Codex + hosted-tracker (or `tracker.kind: memory`) deployment given equivalent normalized work-item inputs (quickstart.md Scenario 3 step 4) (depends on T031)

**Checkpoint**: All three user stories are independently functional and composable; quickstart.md Scenarios 1–3 all pass.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T035 [P] Update `elixir/AGENTS.md` (Docs Update Policy) documenting `tracker.kind: local`, `symphony local-tracker init`, `agent_execution.kind`, and `claude_code.*` as new `WORKFLOW.md` surface
- [x] T036 Run `make all` (format check, `mix specs.check`, `credo --strict`, coverage at the existing 100% threshold, dialyzer) across the full tree including every new module and test, and fix any gate failure (depends on T001–T034)
- [x] T036A Document the `tracker.kind: local` local work-tracking source (including `symphony local-tracker init`) and the `agent_execution.kind`/`claude_code.*` Claude Code execution surface in `elixir/README.md` (operator setup/config, adapter-profile style) and `SPEC.md` (normative extension appendix), so both are discoverable/configurable the same way every existing tracker/execution surface already is; no code or task-content changes (depends on T035)
- [x] T037 Execute `quickstart.md` Scenarios 1–3 front-to-back exactly as written and record results (depends on T036, T036A)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: No dependency on Setup's content, but ordered after it; BLOCKS both User Story 1 and User Story 2 (IV-005's restart-only guarantee must exist before either structural selector is exercised).
- **User Story 1 (Phase 3)**: Depends only on Foundational (T002). Independent of User Story 2.
- **User Story 2 (Phase 4)**: Depends only on Foundational (T002). Independent of User Story 1.
- **User Story 3 (Phase 5)**: Depends on User Story 1 (T012 `local-tracker init`) AND User Story 2 (T022 `ClaudeCode.AppServer`, T027 dispatch resolution) both being complete — this is expected, since US3 is explicitly a composition of US1+US2, not new capability.
- **Polish (Phase 6)**: Depends on all preceding phases.

### Within Each User Story

- US1: `local/store.ex` and `local/init.ex` (T004/T005) are independent of each other (deliberately separate modules per plan.md's structure decision) and unblock everything else in the story.
- US2: T016 (CLI verification) and T017 (behaviour definition) are independent of each other; T022 (`ClaudeCode.AppServer`) depends on both, plus T020 (`MCPServer`).
- US3: purely additive test cases in one file, each building on T031's base scenario.

### Parallel Opportunities

- T004 and T005 (US1) can run in parallel — different files, no dependency between them.
- T008 and T009 (US1) can run in parallel once T004 is done — different files, same single dependency.
- T006 and T007 (US1) can run in parallel — different test files, independent of each other.
- T016, T017, T020, and T024 (US2) can all start in parallel once Foundational (T002) is done — four independent files/activities.
- Once Foundational is done, all of User Story 1 and User Story 2 can proceed in parallel by different contributors.

---

## Parallel Example: User Story 1

```bash
# Launch the two independent module implementations together:
Task: "Implement lib/symphony_elixir/local/store.ex per T004"
Task: "Implement lib/symphony_elixir/local/init.ex per T005"

# Once T004 lands, launch its dependents together:
Task: "Implement lib/symphony_elixir/local/adapter.ex per T008"
Task: "Implement lib/symphony_elixir/local/agent_tool.ex per T009"
```

## Parallel Example: User Story 2

```bash
# Launch these four independent tasks together once Foundational (T002) is done:
Task: "Verify installed Claude Code CLI against research.md R5/R7/R8 per T016"
Task: "Define SymphonyElixir.CodingAgent behaviour per T017"
Task: "Implement lib/symphony_elixir/claude_code/mcp_server.ex per T020"
Task: "Add agent_execution/claude_code embeds to config/schema.ex per T024"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational).
2. Complete Phase 3 (User Story 1).
3. **STOP and VALIDATE**: run quickstart.md Scenario 1 end to end.
4. This alone delivers the fork's foundational premise — Symphony operable with zero hosted-tracker dependency — independent of Claude Code.

### Incremental Delivery

1. Setup + Foundational → structural-config capture ready.
2. Add User Story 1 → validate independently (Scenario 1) → this is the MVP.
3. Add User Story 2 → validate independently (Scenario 2), confirming the existing Codex path is untouched.
4. Add User Story 3 → validate composition (Scenario 3) — no new capability, only confirmation the two already-shipped stories compose safely.
5. Polish: full `make all` gate + full quickstart re-run.

### Parallel Team Strategy

With two contributors: one takes User Story 1 (Phase 3) and one takes User Story 2 (Phase 4) immediately after Foundational (Phase 2) completes — the two stories touch disjoint files (`local/*.ex` + `tracker.ex`/`cli.ex` vs. `coding_agent.ex` + `claude_code/*.ex` + `config/schema.ex`/`config.ex`/`agent_runner.ex`) and have no functional dependency on each other. User Story 3 requires both to be done first.

---

## Notes

- No task in this list reopens `spec.md` or any frozen planning artifact's requirements; every task implements a decision already recorded in `plan.md`/`research.md`/`data-model.md`/`contracts/`.
- T016 is the explicit implementation-time verification point research.md R5/R7/R8 called out as not yet exercised against a live CLI — it must run before T022 is written, not after.
- `dispatchable` is always `true` for the local tracker (T008) — there is no archived/withdrawn concept to implement (research.md R11).
- The `codex_*`-prefixed telemetry field names are deliberately NOT renamed anywhere in this task list (research.md R10) — T022 populates the existing fields.
- `local_tracker_not_initialized` is a startup/config-validation failure only (T011) — it is never exercised as a post-start runtime/polling failure (T014), because `validate_config/1` gates a deployment out of normal scheduling before that state could ever be observed by a dispatch tick.
- T031–T034 (US3) are deterministic, fixture-driven tests suitable for ordinary `mix test`/`make all` runs — none of them requires a real Claude CLI process, model call, network access, or credential, and none of them depends on an LLM correctly following a natural-language instruction. T029 is the sole flag-gated test that exercises the real, installed Claude CLI/provider end to end.
- **T028A** is a repair task inserted out-of-sequence between T028 and T029 (not renumbering T029–T037) after an investigation-only session found T022/T024's original `claude_code.command` default (`--bare`, API-key-only) blocked T029 from using an already-authenticated Claude subscription, and that the fix needed is scope-aware config (`--setting-sources project,local`), not a T022/T023 redesign. See research.md's "R8 Correction Addendum (2026-08-26)" for the full evidence and contracts/workflow-config-fields.md's "Local execution trust model" section for the resulting contract. T029 now depends on T028A in addition to its original dependencies.
