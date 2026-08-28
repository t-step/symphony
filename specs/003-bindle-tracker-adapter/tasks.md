---

description: "Task list for Bindle-Backed Tracker Adapter Implementation"
---

# Tasks: Bindle-Backed Tracker Adapter Implementation

**Input**: Design documents from `/specs/003-bindle-tracker-adapter/` (spec.md, plan.md, research.md,
data-model.md, contracts/bindle-tracker-adapter.md, quickstart.md)

**Tests**: Included — plan.md's Testing section and quickstart.md explicitly require focused tests per
new behavior (real SQLite fixtures, an injectable `:bindle_cli_module` seam, real-fixture-preferred
per research.md R11). Each test task precedes and must FAIL before its paired implementation task lands.

**Organization**: Tasks are grouped by user story per spec.md, but **phase order below reflects actual
implementation dependency, not spec.md's story numbering**. User Stories 1 and 2 and 3 are all Priority
P1 in spec.md; verification against `orchestrator.ex`'s real control flow (research.md R16, plan.md
Technical Context) shows **US1 (adapter read-path) and US3 (admission/continuation predicate split) have
no dependency on each other** and can be built in either order or in parallel, while **US2 (claim
arbitration) depends on both** — on US1 for the adapter module it extends, and specifically on US3's
`Issue.routed?/2` for its fresh-admission-vs-continuation-retry re-validation split (T030 below). See
"Dependencies & Execution Order" for the full graph.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files AND no unresolved dependency on a sibling task in this
  list. Tasks touching the same file (`orchestrator.ex`, `bindle_orchestrator_integration_test.exs`,
  `tracker.ex`) are deliberately left unmarked even where logically independent, to avoid false
  parallelism that would conflict on the same file.
- **[Story]**: US1–US5 per spec.md's five user stories.

---

## Phase 1: Setup

**Purpose**: Confirm there is nothing new to initialize before Foundational work begins.

- [X] T001 [P] ~~Confirm `exqlite ~> 0.30` is already present~~ — **corrected during implementation**: it was not present in `elixir/mix.exs`/`mix.lock` (verified directly; plan.md/research.md's "already present" claim was false). Added `{:exqlite, "~> 0.30"}` to `elixir/mix.exs`, ran `mix deps.get`, confirmed it resolves to `0.40.0` in `elixir/mix.lock` (the version this feature's artifacts already assumed). Corrected the false claim in spec.md/plan.md/research.md R1 in place — see each file's "Correction (implementation-stage)" notes. User approved adding this as a new dependency before proceeding.
- [X] T002 [P] Create the `elixir/lib/symphony_elixir/bindle/` package directory, mirroring `elixir/lib/symphony_elixir/local/`'s shape (plan.md Project Structure) — no files yet, just the package location later tasks write into.

**Checkpoint**: Nothing blocks Foundational — both tasks are pure verification/scaffolding.

---

## Phase 2: Foundational (Blocking Prerequisite)

**Purpose**: The one genuinely cross-cutting seam every later Bindle-specific orchestrator change calls
into — `SymphonyElixir.Tracker`'s new optional callback pair. Nothing else in this feature is foundational
in the "blocks everything" sense: US1 and US3 do **not** depend on each other or on anything beyond this
phase.

**⚠️ CRITICAL**: T024, T026, T028, T030, T032 (User Story 2's orchestrator wiring) cannot compile/land
until T003 exists. US1 and US3 do not need this phase to *start*, but do need it before US2 can begin.

- [X] T003 Add `acquire_issue/2` and `release_issue/2` as `@optional_callbacks`-guarded callbacks to the `SymphonyElixir.Tracker` behaviour, plus public `Tracker.acquire_issue/2`/`Tracker.release_issue/2` functions that resolve the active adapter via `Code.ensure_loaded?/1`/`function_exported?/3` (mirroring `Tracker.validate_config/1`'s existing pattern) and return `:ok` unconditionally when unimplemented, in `elixir/lib/symphony_elixir/tracker.ex` — FR-005, contracts §1.
- [X] T004 [P] Extend `elixir/test/symphony_elixir/tracker_test.exs`: confirm `Tracker.acquire_issue/2`/`release_issue/2` are complete no-ops (`:ok`) for every one of the six existing adapters (asana, github, gitlab, jira, linear, local) — FR-005, User Story 2 Acceptance Scenario 5. (Note: `tracker_test.exs` did not already exist as tasks.md assumed — created fresh, following `TestSupport` conventions.)

**Checkpoint**: The callback shape exists. Phase 3 (US1) and Phase 4 (US3) may now start — **in either
order, or in parallel** — since neither depends on the other or on anything Phase 3/4-specific from this
phase beyond T003 having landed for whichever later touches `orchestrator.ex`.

---

## Phase 3: User Story 1 - Dispatch Bindle-managed work through the existing scheduler, unmodified (Priority: P1)

**Goal**: A configured `tracker.kind: bindle` deployment reads Bindle's published projection and produces
correctly-mapped `Tracker.Issue` structs through the six existing `Tracker` callbacks — no claim
arbitration yet (that's US2).

**Independent Test**: Point `tracker.kind: bindle` at a fixture `symphony-projection.sqlite3` with one
dispatchable row; confirm `fetch_issues_by_states/1`/`fetch_issues_by_ids/1` return a correct `Tracker.Issue`.

**Parallel note**: This entire phase has no dependency on Phase 4 (US3) and may be built concurrently with it.

### Tests for User Story 1 (write first — must fail before their implementation task)

- [X] T005 [P] [US1] Write `elixir/test/symphony_elixir/bindle_projection_test.exs`: real temporary SQLite fixture matching the `task_projection` schema (`PRAGMA user_version = 1`) — `open_and_validate/1` schema-version pass/fail, `fetch_by_states/2`/`fetch_by_ids/2` row mapping (data-model.md §1), fail-loud (not silently-dropped) on a structurally invalid row (research.md R14); **`list_ids/1` returns every task id currently in `task_projection` regardless of `dispatchable`, performs no lifecycle interpretation of any kind, never opens Bindle's canonical ledger file, and surfaces a connection-open/schema-version/query failure the same distinguishable `{:error, _}` way the other three functions do** — FR-003, contracts §5.
- [X] T006 [P] [US1] Write `elixir/test/symphony_elixir/bindle_adapter_test.exs`: `fetch_issues_by_states/1`/`fetch_issues_by_ids/1` return a correctly-mapped `Tracker.Issue` with every unpublished field at its struct default (Acceptance Scenario 1); distinguishable `{:error, _}` on missing/incompatible-version/unreadable projection (Acceptance Scenario 2); read-only-open + never-opens-canonical-file enforcement (Acceptance Scenario 3) — FR-002/FR-003/FR-004.

### Implementation for User Story 1

- [X] T007 [US1] Implement `SymphonyElixir.Bindle.Projection` (`open_and_validate/1`, `fetch_by_states/2`, `fetch_by_ids/2`, **`list_ids/1`**) in `elixir/lib/symphony_elixir/bindle/projection.ex` — read-only URI connection (research.md R1), `PRAGMA user_version` gate (R2), column-name-only queries, fail-loud row validation (R14) for the first three; `list_ids/1` returns every `id` in `task_projection` regardless of `dispatchable`, with no lifecycle interpretation — contracts §5. Depends on: T002, T005. (Uses `Exqlite.Sqlite3`'s low-level API directly — see T001's note on the exqlite dependency correction.)
- [X] T008 [US1] Implement `SymphonyElixir.Bindle.Adapter`'s read path — `@behaviour SymphonyElixir.Tracker`, `fetch_issues_by_states/1`, `fetch_issues_by_ids/1` delegating to `Projection`, `validate_config/1` delegating to `Projection.open_and_validate/1`, plus public `resolve_repo_path/1`/`resolve_projection_path/1`/`resolve_bindle_bin/1`/`resolve_owner_id_path/1` (mirroring `Local.Adapter.resolve_provider_path/2`'s separation of concerns — `finalize_settings/2` cannot resolve workflow-dir-relative defaults itself) — in `elixir/lib/symphony_elixir/bindle/adapter.ex` (contracts §8). Depends on: T007, T006.
- [X] T009 [US1] Add `resolve_tracker_provider("bindle", settings, provider)` to `elixir/lib/symphony_elixir/config/schema.ex` — defaults `bindle_bin` only (the one key with no `workflow_dir()`/`repo_path` dependency); `repo_path`/`path`/`owner_id_path` defaults are applied by `Bindle.Adapter`'s own resolve_* functions at call time (T008) — data-model.md §7, research.md R10/R15.
- [X] T010 [US1] Register `"bindle" => SymphonyElixir.Bindle.Adapter` in `Tracker.@adapters` in `elixir/lib/symphony_elixir/tracker.ex` — FR-001, FR-022. Depends on: T008, T003 (same file as T003 — sequenced after it).
- [X] T011 [P] [US1] ~~Extend `workspace_and_config_test.exs`~~ — **consolidated into `bindle_adapter_test.exs`** (no existing generic "kind selection" test pattern exists in `workspace_and_config_test.exs` for any adapter to extend; each adapter's own kind-selection test lives in its own adapter test file, per the actual codebase convention — verified by grep before writing). Covers `tracker.kind: bindle` selection via `Tracker.adapter_for_kind/1` + `Config.validate!()`, `repo_path`/`path`/`bindle_bin`/`owner_id_path` default resolution, and `validate_config/1` failing loud on a missing/incompatible projection — FR-022, contracts §8.

**Verification**: `mix test test/symphony_elixir/bindle_projection_test.exs test/symphony_elixir/bindle_adapter_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/tracker_test.exs test/symphony_elixir/tracker_issue_test.exs` — 131 tests, 0 failures.

**Checkpoint**: US1 independently testable — a fixture-backed `tracker.kind: bindle` deployment can poll
and produce correct `Tracker.Issue` structs through the unmodified orchestrator (dispatch will not yet
perform real claim arbitration — see US2).

---

## Phase 4: User Story 3 - A just-claimed task is not preempted on the very next poll (Priority: P1)

**Goal**: Split `dispatchable` (admission) from routing/continuation, generically for every tracker, so
reconciliation and multi-turn agent runs never terminate solely because `dispatchable` flips to `false` on
an issue Symphony already holds.

**Independent Test**: Drive a running/blocked issue through reconciliation with `dispatchable: false` but
unchanged active state and routing; confirm no termination/release; confirm terminal/non-active/missing
cases still terminate/release exactly as before.

**Parallel note**: This entire phase has no dependency on Phase 3 (US1) and may be built concurrently with
it — it is a pure Symphony-core correction, testable against every *existing* adapter (Linear, GitHub,
etc.) without the Bindle adapter existing at all. **Phase 5 (US2)'s T030 depends on this phase's T013.**

### Tests for User Story 3 (write first — must fail before their implementation task)

- [X] T012 [P] [US3] Extend `elixir/test/symphony_elixir/tracker_issue_test.exs`: `dispatchable?/1` reads `issue.dispatchable` alone; `routed?/2` reads label match + `continuation_allowed`; `routable?/2` remains the `dispatchable?(issue) and routed?(issue, labels)` composition; `continuation_allowed` defaults to `true` — FR-013, data-model.md §4. (File did not already exist — created fresh.)
- [X] T014 [P] [US3] ~~Extend `elixir/test/symphony_elixir/orchestrator_status_test.exs`~~ — **corrected during implementation**: `reconcile_issue_state/4`/`reconcile_blocked_issue_state/4`'s actual existing unit coverage lives in `core_test.exs` (via `reconcile_issue_states_for_test`/`reconcile_blocked_issue_states_for_test`), not `orchestrator_status_test.exs` (which covers GenServer snapshot/dashboard rendering only — verified by grep, no `reconcile_issue_state` reference anywhere in that file). Extended `core_test.exs` instead: two new tests confirm `dispatchable: false` with unchanged active state/routing does NOT terminate/release (SC-003); also **fixed a genuine regression this change surfaced** in the pre-existing "reassigned away" test, which simulated reassignment via `dispatchable: false` (the old, now-removed mechanism) — updated its fixture to `continuation_allowed: false` (the new signal), since dispatchable no longer gates continuation for any tracker. — FR-014.
- [X] T016 [P] [US3] ~~Extend Symphony's `AgentRunner` test coverage~~ — added to `core_test.exs` (where the existing `continue_with_issue_for_test` coverage already lives, not a separate `agent_runner_test.exs`): confirms `continue_with_issue?/2` returns `{:continue, _}` on `dispatchable: false` alone with unchanged routing — FR-015, Acceptance Scenario 3.

### Implementation for User Story 3

- [X] T013 [US3] Implement the `routable?/2` split in `elixir/lib/symphony_elixir/tracker/issue.ex`: add `continuation_allowed: boolean()` (default `true`) to the `Issue` struct; add `dispatchable?/1`; add `routed?/2` (label match + `continuation_allowed`); keep `routable?/2` as the `dispatchable?/1 and routed?/2` composition, used only by `candidate_issue?/3` — FR-013, data-model.md §3/§4. Depends on: T012.
- [X] T015 [US3] Change `Orchestrator.reconcile_issue_state/4` and `Orchestrator.reconcile_blocked_issue_state/4` in `elixir/lib/symphony_elixir/orchestrator.ex` to consult `Issue.routed?/2` (via a new private `issue_routed?/1` wrapper, alongside the existing admission-only `issue_routable?/1`), never `dispatchable`, for their continuation/release decision — FR-014. Depends on: T013, T014.
- [X] T017 [P] [US3] Change `AgentRunner.continue_with_issue?/2` in `elixir/lib/symphony_elixir/agent_runner.ex` to consult `Issue.routed?/2` (renamed its private `issue_routable?/1` wrapper to `issue_routed?/1`), never `dispatchable` — FR-015. Depends on: T013, T016 (different file from T015 — safe to run in parallel with it).

**Verification**: `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/tracker_issue_test.exs test/symphony_elixir/tracker_test.exs test/symphony_elixir/orchestrator_status_test.exs` — 162 tests, 0 failures.

**Checkpoint**: US3 independently testable — the admission/continuation defect is fixed generically, works
for every existing tracker, verifiable before the Bindle adapter exists at all.

---

## Phase 5: User Story 2 - Real dispatch-time claim arbitration, not a trusted snapshot (Priority: P1)

**Goal**: Real, durable Bindle claim arbitration wired into the orchestrator's dispatch/release path —
acquire-before-spawn, symmetric release, spawn-failure compensation, fresh-admission-vs-continuation-retry
correctness, and crash-recoverable startup reconciliation with bounded per-id retry.

**Independent Test**: Seed two concurrent dispatch attempts against the same dispatchable Bindle task;
confirm exactly one acquisition succeeds.

**Depends on**: Phase 3 (US1 — extends `bindle/adapter.ex`, needs `config/schema.ex`) and Phase 2
(Foundational — `Tracker.acquire_issue/2`/`release_issue/2`). **T030 additionally depends on Phase 4
(US3)'s T013** — this is the one genuine cross-story dependency in this feature; see "Dependencies &
Execution Order."

### 5a. CLI wrapper + owner identity (parallel-safe with each other — different files)

- [X] T018 [P] [US2] Write `elixir/test/symphony_elixir/bindle_cli_test.exs`: `claim/4` constructs `bindle work claim <id> --owner <owner>` with `cd: repo_path`, no `--worktree`/`--branch`; `release/4` constructs `bindle work release <id> --owner <owner>`; exit-code `0` → `{:ok, output}`, non-zero → `{:error, {:bindle_cli_failed, exit_code, output}}`, binary-not-found → `{:error, {:bindle_cli_unavailable, _}}` — FR-009/FR-010, contracts §4.
- [X] T019 [P] [US2] Write `elixir/test/symphony_elixir/bindle_owner_test.exs`: generates and persists an opaque identity on first use; reuses it on subsequent reads; fails loud (does not regenerate) on a corrupt/empty existing file — FR-011, contracts §6.
- [X] T020 [P] [US2] Implement `SymphonyElixir.Bindle.Cli`'s `claim/4` and `release/4` in `elixir/lib/symphony_elixir/bindle/cli.ex` — `System.cmd/3` wrapper, `Application.get_env(:symphony_elixir, :bindle_cli_module, SymphonyElixir.Bindle.Cli)` injection seam mirroring `gitlab/adapter.ex`'s `:gitlab_client_module` pattern (research.md R3/R11) — FR-009/FR-010/FR-018 (this module's `claim`/`release` invoke only Bindle's supported CLI verbs, never a raw database mutation), contracts §4. Depends on: T002, T018.
- [X] T021 [P] [US2] Implement `SymphonyElixir.Bindle.Owner.id/1` in `elixir/lib/symphony_elixir/bindle/owner.ex` — FR-011, contracts §6, data-model.md §5. Depends on: T002, T019.

### 5b. Adapter acquire/release + orchestrator acquire call site

- [X] T022 [US2] Extend `SymphonyElixir.Bindle.Adapter` with `acquire_issue/2` (delegates to `Cli.claim/4` + `Owner.id/1`) and `release_issue/2` (delegates to `Cli.release/4` + `Owner.id/1`) in `elixir/lib/symphony_elixir/bindle/adapter.ex` — FR-009/FR-018 (scoped exclusively to claim/release; never reads/writes a lifecycle-state field), contracts §1/§4. Depends on: T008 (US1), T020, T021.
- [X] T023 [US2] Write `elixir/test/symphony_elixir/bindle_orchestrator_integration_test.exs` — **acquire sub-suite**: `acquire_issue/2` fires immediately before `Task.Supervisor.start_child/2` for a fresh-admission candidate, with no `--worktree`/`--branch`; proceeds to spawn only on `:ok`; skips dispatch without crash/alert on any other result; every non-Bindle adapter's dispatch is unchanged byte-for-byte — FR-006, Acceptance Scenarios 1/2/5, SC-002.
- [X] T024 [US2] Wire `Tracker.acquire_issue/2` into `Orchestrator.spawn_issue_on_worker_host/5`, immediately before `Task.Supervisor.start_child/2`, gated to **fresh-admission mode only** — FR-006. Depends on: T003, T022, T023.

### 5c. Release consolidation + acquire-success/spawn-failure compensation (kept as two distinct, separately-tested units — not folded together)

- [X] T025 [US2] Extend `bindle_orchestrator_integration_test.exs` — **release sub-suite**: `release_issue/2` fires at every existing claim-release point (retry-exhausted, terminal-state, routed-away, missing-issue) via exactly one internal call site, and is NOT called merely because a crash-mid-run retry is scheduled — FR-007/FR-020/FR-021, Acceptance Scenario 3.
- [X] T026 [US2] Consolidate `Tracker.release_issue/2` to fire from exactly one place, `Orchestrator.release_issue_claim/2`: change `terminate_running_issue/3`'s found-running-entry branch to delegate its `claimed`/`blocked`/`retry_attempts`-clearing to `release_issue_claim/2` instead of duplicating it inline — FR-020/FR-021, contracts §2. Depends on: T024, T025.
- [X] T027 [US2] Extend `bindle_orchestrator_integration_test.exs` — **compensation sub-suite**: acquisition succeeding immediately followed by a worker-spawn failure triggers exactly one compensating `release_issue/2` call before the ordinary spawn-failure retry (FR-008). Verify directly against the stubbed CLI boundary's recorded claim state (not the fixture's published-projection row) that the compensating release actually clears Bindle's durable self-claim — removing the block that would otherwise reject the retry's next `acquire_issue/2` as already-claimed. **Do not assert the retry's next acquisition succeeds merely because compensation ran.** The retry remains an ordinary fresh-admission retry (T030): it still requires the fixture's projection row to present `dispatchable: true` at re-validation before `acquire_issue/2` is even attempted — this feature does not add a claim/release-triggered `bindle work publish` to force the projection to reflect the release immediately (FR-028; publish is scoped to T039's `done`-tool path only). Structure the fixture so the projection row is (or becomes) `dispatchable: true` by the time the retry re-validates — reflecting that the durable claim, not the projection, is what release actually fixes — and confirm acquisition then succeeds because the released claim no longer blocks it — SC-006.
- [X] T028 [US2] Implement acquire-success/spawn-failure compensation: in `spawn_issue_on_worker_host/5`'s `{:error, reason} ->` branch, call `release_issue_claim/2` before `schedule_issue_retry/4`, only when acquisition was actually performed for this attempt — FR-008, research.md R12. Depends on: T026, T027.

### 5d. Fresh-admission vs. continuation-retry split (its own explicit unit — this is the retry/claim race fix)

- [X] T029 [US2] Extend `bindle_orchestrator_integration_test.exs` — **retry-split sub-suite**: a crash-mid-run retry of an issue already in `state.claimed` does NOT require `dispatchable = true` at re-validation and does NOT call `acquire_issue/2` a second time — proceeds directly to respawn reusing the held claim. A fresh-admission retry (following T028's compensation release) DOES require `dispatchable = true` at re-validation before it calls `acquire_issue/2` — the fixture MUST set the projection row's `dispatchable` explicitly for this case (do not assume it becomes `true` automatically as a side effect of the compensating release; per T027, release and projection freshness are independent) — FR-016/FR-024, SC-008.
- [X] T030 [US2] Implement the fresh-admission-vs-continuation-retry split: branch `retry_candidate_issue?/2`'s re-validation (reached via `revalidate_issue_for_dispatch/3`/`refresh_issue_for_dispatch/1`, shared by `dispatch_issue/4` and `handle_active_retry/4`) and `spawn_issue_on_worker_host/5`'s acquisition call on `MapSet.member?(state.claimed, issue.id)` — continuation mode uses `Issue.routed?/2` (not `dispatchable`) and skips `acquire_issue/2` entirely — FR-016/FR-024, research.md R16, data-model.md §9a. **Depends on: T013 (Phase 4/US3's `routed?/2`), T028, T029** — this is the feature's one real cross-user-story dependency.

### 5e. Startup reconciliation + bounded retry (isolated — does not depend on 5b/5c/5d beyond Foundational)

- [X] T031 [US2] Extend `bindle_orchestrator_integration_test.exs` — **startup-reconciliation sub-suite**: on startup with `tracker.kind: bindle`, every projected task id gets an owner-scoped `Bindle.Cli.release/4` attempt (via `reconcile_stale_claims/1`, called synchronously in `init/1` before `schedule_tick(state, 0)` — i.e. before the first poll is scheduled) — FR-012. An individual release failure gets bounded follow-up retries via the **dedicated `stale_claim_release_retries` timer mechanism T032 builds** — never via `schedule_issue_retry/4` or `state.retry_attempts` — without blocking normal polling or other tasks' dispatch; an exhausted retry budget logs a persistent, operator-visible failure naming the task id — FR-029, SC-007. **Explicitly assert the isolation boundary**: after a stale-claim release failure and its follow-up retries (whether they eventually succeed or exhaust), `state.retry_attempts` MUST remain unchanged (empty, or containing only genuine coding-agent dispatch retries seeded by the test) — no `{:retry_issue, _, _}` message is ever sent for a stale-claim release, and `Tracker.fetch_issues_by_ids/1`/`do_dispatch_issue/4` are never invoked as a side effect of a stale-claim retry attempt or its exhaustion.
- [X] T032 [US2] Implement `reconcile_stale_claims/1` in `elixir/lib/symphony_elixir/orchestrator.ex` plus a **dedicated, narrowly-scoped retry mechanism separate from `schedule_issue_retry/4`** (verified against `schedule_issue_retry/4`'s actual implementation, research.md — its `state.retry_attempts` entries carry coding-agent-dispatch-specific fields (`identifier`, `issue_url`, `error`, `worker_host`, `workspace_path`) and its receiving `handle_info({:retry_issue, ...}, state)` clause re-enters `handle_retry_issue/4`'s fetch/dispatch state machine; reusing either would let a stale-claim-release failure accidentally enter coding-agent retry/dispatch machinery, and would misrepresent dashboard data built from `state.retry_attempts`). No generic timer abstraction exists to extract instead — `Process.send_after/3` is already the raw primitive `schedule_issue_retry/4` and `schedule_tick/2` each use directly, so this task follows that same existing convention with its own state and message, not a new framework:
  - `reconcile_stale_claims/1`: read every id via `Bindle.Projection.list_ids/1` (T007), call `Bindle.Cli.release/4` with the persisted owner identity (T020/T021) for each, continuing past individual failures — called once, synchronously, from `init/1` before `schedule_tick(state, 0)` (mirroring `run_terminal_workspace_cleanup/0`'s existing synchronous-startup-step pattern), so the initial sweep completes before the first poll is scheduled.
  - New `state.stale_claim_release_retries` field (a map keyed by task id, distinct from and never written to/read from `state.retry_attempts`), holding only `%{attempt, timer_ref, retry_token}` — no coding-agent/worker/workspace fields, since none apply.
  - A private `schedule_stale_claim_release_retry/3` mirroring `schedule_issue_retry/4`'s own token-guard pattern (cancel any prior timer for this id, `make_ref()` a fresh token, `Process.send_after(self(), {:retry_stale_claim_release, issue_id, retry_token}, delay_ms)`, store the entry in `state.stale_claim_release_retries`) for any id whose release failed, up to a small fixed attempt bound.
  - A new `handle_info({:retry_stale_claim_release, issue_id, retry_token}, state)` clause, added before the module's catch-all `handle_info/2` — validates the token against the stored entry (discarding a stale/cancelled timer message), calls **only** `Bindle.Cli.release/4` again for that id (never `Tracker.fetch_issues_by_ids/1`, never `do_dispatch_issue/4`, never anything in the `{:retry_issue, ...}` path) — on success, clears the entry; on failure, reschedules via `schedule_stale_claim_release_retry/3` if under the attempt bound, or logs a persistent, operator-visible failure naming the task id and clears the entry once exhausted.
  - Normal polling (`schedule_tick(state, 0)`) proceeds immediately after the initial sweep in `init/1` returns, regardless of any pending follow-up retries — an unrecovered stale claim for one task never blocks dispatch of any other task.

  FR-012/FR-029/FR-028 (this sweep and its retries call only `Cli.release/4`, never `publish` — claim/release correctness does not depend on projection freshness), research.md R5/R19, contracts §7. **Depends on: T003, T007 (now includes `Projection.list_ids/1`), T020, T021** — deliberately not sequenced after T024/T026/T028/T030, since it shares no logic or state with them beyond the CLI wrapper and owner identity.

**Checkpoint**: US2 independently testable — claim arbitration, release symmetry, spawn-failure
compensation, retry-continuation correctness, and crash-recoverable startup reconciliation all verified.

---

## Phase 6: User Story 4 - Every existing tracker's behavior is provably unchanged (Priority: P2)

**Goal**: Close Asana's real `completed`-vs-section-name gap and confirm Linear's reassignment-stop and
every other adapter's behavior is unaffected.

**Independent Test**: Run every existing adapter's current dispatch/continuation/release suite unmodified
in outcome; separately confirm Asana's newly-populated `continuation_allowed` catches a completed-but-
unmoved task.

**Depends on**: Phase 4 (US3)'s T013 (`continuation_allowed` field must exist before any adapter can
populate it).

- [X] T033 [P] [US4] Extend `elixir/test/symphony_elixir/asana_adapter_test.exs`: `continuation_allowed` is populated from `task["completed"] == false`, independent of `resource_subtype`/section/`state` — a task that completes without its section changing correctly flips `continuation_allowed` to `false` — FR-017, SC-010.
- [X] T034 [P] [US4] Populate `continuation_allowed` in `elixir/lib/symphony_elixir/asana/client.ex` from `task["completed"] == false` — FR-013/FR-017, research.md R9. Depends on: T013, T033.
- [X] T035 [P] [US4] Extend Linear's client test coverage: `continuation_allowed` carries Linear's existing `assigned_to_worker?/2` computation unchanged, preserving the reassignment-stop behavior — Acceptance Scenario 1.
- [X] T036 [P] [US4] Populate `continuation_allowed` in `elixir/lib/symphony_elixir/linear/client.ex` from the existing `assigned_to_worker?(assignee, assignee_filter)` computation, surfaced as its own field instead of folded silently into `dispatchable` — FR-013/FR-017, research.md R9. Depends on: T013, T035.
- [X] T037 [US4] Run and confirm every existing adapter's own dispatch/release/continuation suite (`core_test.exs`, `orchestrator_status_test.exs`, GitHub/GitLab/Jira coverage) passes unmodified in outcome, and confirm `acquire_issue/2`/`release_issue/2` are never called against a non-Bindle adapter — SC-004, Acceptance Scenario 3. Depends on: Phase 4 and Phase 5 complete, T034, T036.

**Checkpoint**: US4 confirms zero regression across every existing tracker, and the previously-open Asana
gap is actually closed.

---

## Phase 7: User Story 5 - An agent may report its own bound task done; Bindle's milestone/dependency/evidence model stays inside Bindle (Priority: P3)

**Goal**: One narrow, session-scoped, agent-invoked tool marks the session's own bound task `done`,
followed by a best-effort `publish`.

**Independent Test**: An agent's coding session invokes the tool for its own bound task; confirm `bindle
work done <id>` fires for exactly that id, never a model-supplied one, followed by `bindle work publish`.

**Depends on**: Phase 3 (US1 — `bindle/adapter.ex`, config wiring) and Phase 5/5a (US2's `cli.ex` file must
already exist with `claim/4`/`release/4` before this phase extends it with `done/3`/`publish/2`).

- [X] T038 [P] [US5] Extend `bindle_cli_test.exs`: `done/3` constructs `bindle work done <id>` with `cd: repo_path`, **no `--owner`**; `publish/2` constructs `bindle work publish` with `cd: repo_path`, **no `--owner`**; exit-code/stderr interpretation matches `claim`/`release`'s existing convention — FR-025/FR-026/FR-027, contracts §4.
- [X] T039 [US5] Add `done/3` and `publish/2` to `SymphonyElixir.Bindle.Cli` in `elixir/lib/symphony_elixir/bindle/cli.ex` — FR-025/FR-026/FR-027, contracts §4. Depends on: T020 (same file — sequenced after US2's `claim`/`release`), T038.
- [X] T040 [P] [US5] Write `elixir/test/symphony_elixir/bindle_agent_tool_test.exs`: target id resolved exclusively from `opts[:issue].id`, ignoring any model-supplied argument (`inputSchema` declares no task-id parameter at all); calls `done/3` then, on success, `publish/2`; a `done` failure is returned distinguishably; **a `publish` failure after a successful `done` is surfaced as a distinct field in the result and does NOT trigger a second `done` call** — FR-025/FR-026/FR-027, SC-009.
- [X] T041 [US5] Implement `SymphonyElixir.Bindle.AgentTool` (`tool_specs/0`, `execute/3`) in `elixir/lib/symphony_elixir/bindle/agent_tool.ex` — FR-025/FR-026/FR-027/FR-023 (the one narrow exception FR-023 authorizes: task-level `done` is Bindle's own supported write, asserted by the agent, not a reconciliation policy or semantic-correctness judgment Symphony makes), contracts §9, data-model.md §10. Depends on: T039, T040.
- [X] T042 [US5] Wire `SymphonyElixir.Bindle.Adapter`'s `agent_tool_specs/0`/`execute_agent_tool/3` to delegate to `AgentTool` in `elixir/lib/symphony_elixir/bindle/adapter.ex` — FR-025/FR-019 (this is the one narrow, agent-invoked exception FR-019 permits; no orchestrator-owned API is added), contracts §1. Depends on: T008 (US1), T041.
- [X] T043 [P] [US5] Extend adapter-level test coverage confirming the Bindle adapter exposes exactly one agent tool, scoped to the session's bound task, and that no other code path (orchestrator-owned `acquire_issue/2`/`release_issue/2` included) can invoke `done`/`publish` — FR-019/FR-023, Acceptance Scenario 1, SC-005.

**Checkpoint**: US5 independently testable — agent-triggered completion + best-effort publish, fully
isolated from the claim/release seam (T032's startup sweep and T024/T026/T028/T030's dispatch/release path
never call `done`/`publish`).

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Whole-suite confirmation and the manual proof quickstart.md requires before this feature is
considered complete.

- [X] T044 [P] Run `mix test` (full suite); confirm only the two pre-existing, already-logged flaky
  wall-clock tests (`orchestrator_status_test.exs` "restarts stalled workers" — projectmem #0002,
  `core_test.exs` "abnormal worker exit increments retry attempt progressively" — projectmem #0005) may
  intermittently fail, unrelated to this feature — quickstart.md. **Result: 507 tests, 0 failures, 7 skipped
  (the 7 skipped are pre-existing `*_live_e2e_test.exs` files requiring live provider credentials —
  unrelated to this feature, unchanged skip count from before). Neither known-flaky test flaked this run.**
- [X] T045 Execute quickstart.md's manual end-to-end proof against a real (or fixture) Bindle repository —
  SC-001 (poll, dispatch, and run a coding-agent session against a dispatchable Bindle task through the
  unmodified orchestrator/agent-runner path): dispatch, claim visibility, non-preemption, terminal release,
  spawn-failure compensation (fresh-admission retry), continuation-retry (no re-claim), crash-recovery
  startup sweep with bounded retry, and agent-triggered `done`+`publish` including a simulated
  publish-failure-after-done case. **Fully discharged (2026-08-27)** by an independent live cross-repo
  proof against a real, editable-installed `bindle` binary — Bindle `main` @ `dace8f68`, Symphony
  `development` @ `3aef417` — using a disposable real Bindle repository and no CLI mocking (calls were
  only observed via a pass-through spy, never faked). Every quickstart.md scenario passed against real
  ledger/projection SQLite state, independently confirmed via direct SQL: projection compatibility;
  real claim arbitration including Bindle's genuine `already_claimed` rejection of a second claim;
  continuation under a held claim (no re-claim, no premature release); release and fresh re-admission;
  spawn-failure compensation (real compensating release, retry treated as fresh admission, not rejected);
  agent-scoped `done` auto-followed by real `publish`, unblocking the downstream chained task; the
  done-succeeds/publish-fails partial failure (no duplicate `done`; a later solo `publish` converges the
  projection); and startup stale-claim recovery plus its dedicated bounded retry on an injected real
  release failure, confirmed isolated from `state.retry_attempts`. Full suite: 511 tests, 0 unexpected
  failures (only the two pre-existing, already-logged wall-clock flakes). No defects found in either
  repository; no source changes were required.
  **Residual verification boundaries** (properties of any point-in-time integration proof, not open
  feature work): concurrent claims from multiple Symphony deployments against one Bindle repo were not
  exercised; a real coding-agent session invoking `bindle_mark_task_done` mid-turn was not exercised
  (only the tool's host-side execution path was — the part this feature owns); this proof is pinned to
  Bindle `dace8f68` and does not cover a materially different future Bindle CLI release.

---

## Dependencies & Execution Order

### Phase Dependency Graph (the actual graph, not spec.md's priority ordering)

```
Setup (T001-T002)
  └─→ Foundational (T003-T004)
        ├─→ US1 (T005-T011)  ─────────────┐   (US1 and US3 are mutually independent — parallel-safe)
        └─→ US3 (T012-T017)  ─────────────┤
                                            ├─→ US2 (T018-T032)
                              T013 ─────────┘        │   (T030 alone needs T013 from US3;
                                                      │    everything else in US2 needs only US1+Foundational)
                                            US1 ──────┘
        US3 (T013) ─────────────────────────────→ US4 (T033-T037)
        US1 (T008/T009) + US2 (T020) ──────────→ US5 (T038-T043)
                                            All stories complete ─→ Polish (T044-T045)
```

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. Blocks Phase 5 (US2) only — Phase 3 (US1) and Phase 4
  (US3) do not need it to *begin*, only Phase 5's `orchestrator.ex`/`tracker.ex` edits do.
- **US1 (Phase 3)** and **US3 (Phase 4)**: Both depend only on Foundational. **No dependency on each
  other** — genuinely parallelizable, whether by two engineers or two agents in separate worktrees.
- **US2 (Phase 5)**: Depends on US1 (extends `bindle/adapter.ex`, reuses `config/schema.ex`) and
  Foundational. Its one task with a cross-story dependency is **T030**, which additionally requires US3's
  T013 (`Issue.routed?/2`). Every other US2 task (5a, 5b, 5c, 5e) needs only US1 + Foundational.
- **US4 (Phase 6)**: Depends on US3's T013 only (the `continuation_allowed` field). Does **not** depend on
  US2 for its adapter-population tasks (T033-T036); T037's full-suite regression run is more meaningful
  once US2/US3 have landed, so it is sequenced last within this phase.
- **US5 (Phase 7)**: Depends on US1 (adapter module, config) and, for `cli.ex`'s `done/3`/`publish/2`
  addition (T039), on US2's T020 having already created that file. Does not depend on US2's orchestrator
  wiring (T022-T032) at all — the agent tool shares no code path with the claim/release seam.
- **Polish (Phase 8)**: Depends on every phase being complete.

### Parallel Execution Opportunities

- **Setup**: T001 ∥ T002.
- **Phase-level**: Phase 3 (US1, 7 tasks) ∥ Phase 4 (US3, 6 tasks) — the single largest parallelization
  opportunity in this feature; two engineers/agents can complete both phases concurrently with zero
  coordination beyond both landing before Phase 5 begins.
- **Within US2**: 5a's T018/T019 (tests, different files) ∥ each other; T020/T021 (impl, different files)
  ∥ each other. **5e (T031-T032, startup reconciliation) has no dependency on 5b/5c/5d** and may be
  implemented and merged independently, in parallel with 5b/5c/5d, once 5a lands — it shares only
  `bindle/cli.ex`/`bindle/owner.ex` and `bindle_orchestrator_integration_test.exs` (same test file as
  5b/5c/5d, so coordinate on that file, but the `orchestrator.ex` production-code edit itself, T032, is
  fully independent of T024/T026/T028/T030's edits to the same file — sequence T032 relative to them only
  to avoid a merge conflict, not because of a real logical dependency).
- **Within US4**: T033/T034 (Asana) ∥ T035/T036 (Linear) — different files, zero shared state.
- **Within US5**: T038 ∥ T040 (different test files).

### What Is Deliberately NOT Marked Parallel

- `bindle_orchestrator_integration_test.exs`'s five sub-suites (T023, T025, T027, T029, T031) — same file.
  Logically independent, but marking them `[P]` would invite concurrent-write conflicts; sequence them by
  landing order instead.
- `orchestrator.ex`'s five production edits (T024, T026, T028, T030, T032) — same file, same reason.
- `tracker.ex`'s two edits (T003, T010) — same file.

---

## Implementation Strategy

### MVP First

US1 alone (Phase 1 → 2 → 3) proves the read path end-to-end against a fixture, but is not independently
*useful* without US2 (no real claim arbitration = unsafe against a real Bindle repo with concurrent
readers). The smallest genuinely deployable increment is **US1 + US2 + US3** (Phases 1-5) — real dispatch,
real claim safety, and the non-preemption fix together. US4 and US5 are additive value on top: US4 is a
regression/compatibility guarantee, US5 is the agent-completion capability.

### Incremental Delivery

1. Setup + Foundational.
2. US1 ∥ US3 (parallel) → both checkpoints pass independently.
3. US2 (needs both) → claim arbitration, retry correctness, startup recovery all verified. **This is the
   first point at which a Bindle-backed deployment is safe to run against a real repository.**
4. US4 → confirm zero regression, Asana gap closed.
5. US5 → agent-triggered completion.
6. Polish → full-suite run + manual proof.

### If Staffed for Parallel Work

- Two engineers/agents: one takes US1, the other takes US3, from the moment Foundational lands. Both
  converge before US2 starts.
- A third engineer/agent can begin US2's 5a (CLI wrapper + owner identity) as soon as Foundational lands,
  since 5a depends on neither US1 nor US3 directly (only 5b's `adapter.ex` extension needs US1, and only
  5d's retry-split needs US3) — this shortens US2's own critical path.
