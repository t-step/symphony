# Feature Specification: Bindle-Backed Tracker Adapter Implementation

**Feature Branch**: `003-bindle-tracker-adapter` (Spec Kit feature identifier only; per the fork's workflow — see `001-local-tracker-multi-agent`/`002-bindle-integration` — no separate git branch is created for this feature; work stays on `development`)

**Created**: 2026-08-27

**Status**: Draft

**Input**: User description: "Implement the Bindle-backed Tracker adapter for Symphony as a bounded implementation feature (not another architecture exploration), grounded strictly against specs/002-bindle-integration/ (the frozen, authoritative architecture contract) and independently re-verified against Bindle's actual current implementation and Symphony's actual current source. Scope: (1) a real Bindle Tracker adapter reading Bindle's published read-only SQLite projection; (2) a narrow, optional acquisition/release Tracker callback pair wired into the orchestrator's dispatch/release call sites, with call-site timing, crash recovery, and owner identity resolved as real implementation decisions; (3) a required runtime fix splitting the admission (dispatchable) gate from the continuation/routing gate so a successfully-claimed, now-dispatchable:false item is not preempted, while preserving Linear's and Asana's real per-adapter continuation behavior; (4) an explicit constraint that Bindle's dependency/blocking/milestone/evidence/completion/reconciliation logic is never reconstructed inside Symphony. Includes focused tests using a real temporary SQLite projection fixture and a mockable Bindle-CLI boundary, and an end-to-end proof if feasible. Excludes mechanical evidence verification and any Bindle-side or convenience-UX work."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dispatch Bindle-managed work through the existing scheduler, unmodified (Priority: P1)

An operator configures a Symphony deployment with `tracker.kind: bindle` pointing at a Bindle repository's published projection artifact. Symphony polls it exactly like any other tracker, sees a dispatchable task, and the orchestrator/agent-runner path handles it with no code path aware it originated from Bindle.

**Why this priority**: Without a working adapter that produces a correct `Tracker.Issue`, nothing else in this feature has a caller — this is the feature's entire reason to exist, and it is the seam `002-bindle-integration` FR-001/FR-002/FR-004 already fixed the contract for.

**Independent Test**: Point `tracker.kind: bindle` at a real (or fixture) `symphony-projection.sqlite3` containing one dispatchable `task_projection` row; confirm Symphony's tracker adapter returns a `Tracker.Issue` with the correct fields populated and every other field at its struct default, using only the six existing `Tracker` callbacks — no new orchestrator-facing type or module.

**Acceptance Scenarios**:

1. **Given** a published projection with one dispatchable row (`id`, `identifier`, `title`, `description`, `status = "open"`, `dispatchable = 1`, `created_at`), **When** the Bindle adapter's `fetch_issues_by_states/1` or `fetch_issues_by_ids/1` is called, **Then** it returns a `Tracker.Issue` with `id`, `identifier`, `title`, `description` populated verbatim, `state` set from `status` with no synthesis, `dispatchable: true`, `created_at` parsed, and every other `Issue` field (`native_ref`, `priority`, `branch_name`, `url`, `assignee_id`, `labels`, `blocked_by`, `updated_at`) left at its existing struct default.
2. **Given** the projection file does not exist, has a `PRAGMA user_version` other than the one value this adapter supports, or cannot be opened, **When** the adapter attempts a read, **Then** it returns a distinguishable `{:error, _}` result Symphony's existing tracker/source failure handling already tolerates (skip this poll tick, retry next), never a partial or silently-misread result and never a crash.
3. **Given** the adapter is configured, **When** it opens the projection artifact, **Then** it does so using SQLite's own read-only open mode, issues no write/migration/repair statement against it under any code path, and never opens any file other than the one configured projection path (in particular, never a Bindle canonical ledger file).

---

### User Story 2 - Real dispatch-time claim arbitration, not a trusted snapshot (Priority: P1)

An operator running Symphony against Bindle-managed work needs Symphony to never treat two workers — two poll cycles, or in a future multi-instance deployment, two processes — as having acquired the same Bindle task, even though the projection's `dispatchable` fact is a periodically-refreshed snapshot that can be stale by the time Symphony actually dispatches.

**Why this priority**: This is `002-bindle-integration` FR-015/FR-016's load-bearing seam. Without it, `dispatchable: true` would be silently treated as a durable acquisition guarantee it was never designed to be.

**Independent Test**: Seed two concurrent dispatch attempts against the same dispatchable Bindle task (via a stubbed CLI boundary that lets exactly one "win"); confirm exactly one acquisition succeeds and the other is treated as "not currently available" — skipped, not an error, crash, or alert.

**Acceptance Scenarios**:

1. **Given** a Bindle task whose projection record reads `dispatchable: true`, **When** the orchestrator is about to dispatch it, **Then** it calls the adapter's `acquire_issue/2` callback immediately before spawning the coding-agent `Task`, and only proceeds to spawn on a successful (`:ok`) result; any other result skips dispatching that item this cycle, exactly as an ordinary failed `candidate_issue?/3` check does today.
2. **Given** the acquisition callback's underlying call is Bindle's own `bindle work claim <id> --owner <owner>` CLI invocation, **When** two concurrent attempts race for the same task, **Then** Bindle's own claim arbitration (a single-row insert keyed on the task id) guarantees exactly one succeeds; the loser's non-zero exit is mapped to `{:error, _}`, never raised or crashed on.
3. **Given** an issue reaches any of the orchestrator's existing claim-release points (retry-exhausted / terminal-state transition / routed-away / missing-issue detection), **When** that release point fires, **Then** the orchestrator calls `release_issue/2` at that same point — and does **not** call it merely because a retry is being scheduled, since the same workspace/branch is intentionally reused across retry backoff.
4. **Given** every tracker adapter that does not implement `acquire_issue/2`/`release_issue/2` (asana, github, gitlab, jira, linear, local), **When** the orchestrator dispatches or releases an issue from one of those trackers, **Then** its behavior is unchanged, byte-for-byte, from before this feature — the callback pair is a complete no-op for it.
5. **Given** a Symphony process crash after a successful acquisition but before that task's coding-agent run is fully underway, **When** Symphony next starts up, **Then** startup-time reconciliation releases this Symphony instance's own stale claims (identified by this instance's persisted owner identity) rather than leaving them stranded forever, since Bindle's claims carry no expiry of their own.

---

### User Story 3 - A just-claimed task is not preempted on the very next poll (Priority: P1)

An operator needs a Bindle task Symphony has successfully claimed and started executing to keep running even though the next poll's projection record for that same task now reads `dispatchable: false` — the expected, ordinary result of Bindle correctly reporting a claimed item as unavailable to other acquirers.

**Why this priority**: This is the required runtime correctness fix (`002-bindle-integration` FR-017). Without it, the ordinary claim-then-dispatch sequence User Story 2 requires causes Symphony's own reconciliation to terminate the execution it just started, on the very next poll — a genuine, verified contradiction, not a hypothetical one, since `Orchestrator.reconcile_issue_state/4`, `reconcile_blocked_issue_state/4`, and `AgentRunner.continue_with_issue?/2` all three currently gate continuation on the same combined `Issue.routable?/2` predicate that includes `dispatchable`.

**Independent Test**: Drive a running (or blocked) issue through reconciliation with a refreshed `Issue` whose `dispatchable` is `false` but whose `state` is still active and whose routing/label match is unchanged; confirm the running agent is NOT terminated and the held claim/block is NOT released, while confirming a terminal-state transition, a non-active state, or the issue disappearing from the tracker's visible set still terminates/releases exactly as before.

**Acceptance Scenarios**:

1. **Given** a running issue whose refreshed projection record now has `dispatchable: false` but an unchanged active `state` and unchanged routing (labels still match; for adapters with an assignment signal, still assigned to this worker), **When** `Orchestrator.reconcile_issue_state/4` runs, **Then** it does not terminate the running agent — reconciliation must consult only the continuation/routing concern, never `dispatchable`, for this decision.
2. **Given** the same scenario for a blocked issue, **When** `Orchestrator.reconcile_blocked_issue_state/4` runs, **Then** it does not release the held block.
3. **Given** the same scenario mid-run, **When** `AgentRunner.continue_with_issue?/2` evaluates whether to continue a multi-turn agent run, **Then** it returns `{:continue, _}`, not `{:done, _}`, on `dispatchable` alone.
4. **Given** an issue that moves to a terminal state, moves to a non-active state, is no longer routed to this worker (label mismatch, or — for Linear — reassigned to someone else), or disappears entirely from the tracker's fetched set, **When** reconciliation runs, **Then** it still terminates the running agent / releases the held block exactly as it does today — this fix narrows only the role `dispatchable` plays, and changes none of these other checks.
5. **Given** the legitimate admission-path usage in `candidate_issue?/3` (via `should_dispatch_issue?/4`, already scoped to issues not already running/claimed/blocked), **When** this feature's fix is applied, **Then** that code path is unchanged — `dispatchable` continues to gate whether an issue not already running/claimed/blocked may be newly dispatched.

---

### User Story 4 - Every existing tracker's behavior is provably unchanged (Priority: P2)

An operator running Symphony against GitHub, GitLab, Jira, Linear, Asana, or the standalone local tracker needs certainty that adding the Bindle adapter and the admission/continuation fix changes nothing about how their own deployment already behaves — including subtle existing behaviors like Linear's assignee-reassignment continuation stop and Asana's `completed`-vs-section-name handling.

**Why this priority**: `002-bindle-integration`'s entire premise (FR-004, Constitution II/VII) is that this integration adds no Bindle-specific branch to shared orchestration code and regresses nothing. This story is the regression-safety net the other stories' changes are checked against.

**Independent Test**: Run each existing adapter's current dispatch/continuation/release test coverage unmodified in outcome (tests may be extended, not weakened) before and after this feature's changes; confirm identical pass/fail behavior, with Linear's and Asana's specific continuation semantics re-verified explicitly rather than assumed preserved.

**Acceptance Scenarios**:

1. **Given** Linear's adapter populates an issue-still-assigned-to-this-worker signal today, **When** that signal goes false (reassigned) for a running issue, **Then** continuation still stops for that reason, unaffected by this feature's split of admission from routing.
2. **Given** Asana's adapter's existing `completed`-vs-section-name handling, **When** this feature's changes are applied, **Then** that existing behavior is preserved or, if a genuine gap is found, explicitly documented as a knowing, separate trade-off — never silently dropped.
3. **Given** any of the six existing adapters, **When** the orchestrator dispatches or releases an issue from it, **Then** `acquire_issue/2`/`release_issue/2` are never called against it in a way that changes observable behavior (the callback pair is optional and unimplemented for all six).

---

### User Story 5 - Bindle's own lifecycle model stays inside Bindle (Priority: P3)

A team integrating Bindle-managed work needs assurance that this feature does not quietly grow into a second place where Bindle's dependency/blocking, milestone, evidence, completion, or reconciliation logic is reconstructed or decided.

**Why this priority**: Lower priority than the runtime seam itself, but explicitly called out because the natural next mistake, once a working adapter and a claim/release seam exist, is to keep adding "just one more" Bindle-aware capability until the boundary `002-bindle-integration` fixed erodes.

**Independent Test**: Confirm the only Bindle-owned write operations this feature's code calls are the claim/release/done CLI verbs; confirm no code path reads or interprets Bindle's dependency, blocking, milestone, or evidence tables/columns; confirm any lifecycle-mutation tool exposed to a coding-agent session is scoped to the one work item bound to that session, mirroring the standalone local tracker's existing `local_tracker_set_state` scope restriction.

**Acceptance Scenarios**:

1. **Given** a coding-agent session working a Bindle-managed item, **When** it needs to record lifecycle progress, **Then** it does so only through Symphony's existing agent-invoked, host-executed tool boundary (`agent_tool_specs/0`/`execute_agent_tool/3`), scoped to that session's own bound item — never an orchestrator-owned API, and never a raw SQL mutation.
2. **Given** this feature's full implementation, **When** reviewed against `002-bindle-integration`'s Non-Goals, **Then** no dependency graph, milestone concept, evidence-validation logic, or reconciliation policy has been introduced inside Symphony.

---

### Edge Cases

- What happens when the projection artifact is temporarily unreachable during a poll or reconciliation pass? Symphony MUST treat this the same as any other tracker/source outage — skip the affected poll tick or reconciliation pass, retry next, leave already-running attempts undisturbed (`002-bindle-integration` FR-008).
- What happens when the `bindle` CLI binary is not on `$PATH`, or the configured Bindle repository path does not exist? `acquire_issue/2`/`release_issue/2` MUST return `{:error, _}` distinguishably (e.g. `{:error, {:bindle_cli_unavailable, _}}`), never crash the orchestrator process; this is treated as an acquisition/release failure, not a work-item attempt failure.
- What happens when Symphony restarts and this instance previously held Bindle claims from a run that crashed mid-attempt? Startup-time reconciliation MUST attempt to release this instance's own stale claims (via its persisted owner identity) before resuming normal polling — this is a genuinely new capability this feature must add, not an existing mechanism being reused.
- What happens if `release_issue/2`'s underlying CLI call itself fails (e.g. Bindle process unreachable at release time)? The orchestrator's in-memory release bookkeeping (`release_issue_claim/2`, `terminate_running_issue/3`) MUST proceed regardless — a release-call failure is logged, never allowed to leave Symphony's own in-memory state stuck holding a claim it believes it should have released; the resulting Bindle-side stale claim is recovered by the startup-time reconciliation above, not retried synchronously.
- What happens when two Bindle tasks resolve to the same computed workspace key (identifier collision)? Out of scope for this feature — `002-bindle-integration`'s Key Entities require `identifier` be unique within its configured tracker scope, same as every existing adapter; this feature does not add new collision handling beyond what already exists.
- What happens when a retry is scheduled for an already-acquired issue (worker crashed but Bindle claim held)? `release_issue/2` MUST NOT be called merely because a retry is scheduled — the same workspace/branch and the same Bindle claim are intentionally reused across retry backoff (`002-bindle-integration` FR-015).
- What happens if an operator configures `tracker.kind: bindle` with a Bindle repository path that has never published a projection (`.bindle-work/symphony-projection.sqlite3` absent)? This MUST be handled identically to "projection unreadable" above — a clear, operator-visible tracker/source failure, not a crash and not an empty-but-successful poll.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST provide a new `SymphonyElixir.Bindle.Adapter` module implementing the `SymphonyElixir.Tracker` behaviour, registered under a new `"bindle"` key in `SymphonyElixir.Tracker.@adapters`, following the same per-adapter package convention as `local/`, `github/`, `gitlab/`, `jira/`, `linear/`, `asana/`.
- **FR-002**: The Bindle adapter's `fetch_issues_by_states/1` and `fetch_issues_by_ids/1` MUST read only the configured Bindle-published projection artifact (a physically separate SQLite file from any Bindle canonical ledger file), opened exclusively via SQLite's own read-only open mode, and MUST validate the artifact's schema-version marker before trusting its contents; an incompatible version, missing file, or unreadable artifact MUST produce a distinguishable `{:error, _}` result, never a partial or silently-misread one, and MUST route through Symphony's existing tracker/source failure handling (skip poll tick, retry next).
- **FR-003**: The Bindle adapter MUST map each projection row onto `Tracker.Issue` by column name (never positionally): `status` passes through verbatim to `state` with no synthesis; `dispatchable` passes through verbatim; `id`, `identifier`, `title`, `description`, `created_at` pass through verbatim; every other `Issue` field not published by the projection (`native_ref`, `priority`, `branch_name`, `url`, `assignee_id`, `labels`, `blocked_by`, `updated_at`) is left at its existing struct default.
- **FR-004**: The Bindle adapter MUST NOT under any circumstance create, migrate, or repair the projection artifact, and MUST NOT open any Bindle-owned database file other than the one configured projection path.
- **FR-005**: `SymphonyElixir.Tracker` MUST gain one new, narrow, `@optional_callbacks`-guarded pair — `acquire_issue/2` and `release_issue/2` — with a shape carrying no adapter-specific vocabulary, such that every one of the six existing adapters (asana, github, gitlab, jira, linear, local) that does not implement them is completely unaffected, byte-for-byte.
- **FR-006**: The orchestrator MUST call the active adapter's `acquire_issue/2`, when implemented, immediately before spawning the coding-agent `Task` for a candidate issue, and MUST only proceed to spawn on a successful result; any other result MUST skip dispatching that issue for the current poll cycle without crashing or alerting, exactly as an ordinary failed admission check does today.
- **FR-007**: The orchestrator MUST call the active adapter's `release_issue/2`, when implemented, at every existing point it releases its own claim/block bookkeeping today (retry-exhausted, terminal-state transition, routed-away, missing-issue detection) — and MUST NOT call it solely because a retry is being scheduled for an issue whose workspace/branch is being intentionally reused.
- **FR-008**: The Bindle adapter's implementation of `acquire_issue/2`/`release_issue/2` MUST call only Bindle's own supported CLI write surface (`bindle work claim`, `bindle work release`) — reading the CLI's exit code and stderr/stdout output per its own documented exit-code convention — and MUST NOT issue a raw SQL mutation against any Bindle-owned database file, canonical or published.
- **FR-009**: The Bindle adapter MUST invoke the `bindle` CLI with its working directory (`cwd`) set to the operator-configured Bindle repository path, since the CLI resolves its target ledger from the invoking process's current working directory and accepts no repository-path flag.
- **FR-010**: Symphony MUST define and persist a stable, deployment-local owner-identity string used as the `--owner` argument to every `bindle work claim`/`release` call, reused across restarts of the same deployment (new state; nothing existing is repurposed for this).
- **FR-011**: Symphony MUST perform startup-time reconciliation that attempts to release, via `bindle work release`, any Bindle claims this deployment's own persisted owner identity still holds from a prior run, before resuming normal polling — addressing the crash-recovery gap `002-bindle-integration` FR-015 identifies as an open design question this feature must resolve.
- **FR-012**: `SymphonyElixir.Tracker.Issue`'s combined admission-and-routing predicate (currently `routable?/2`) MUST be split into two distinct concerns: an admission concern (`dispatchable` alone) and a continuation/routing concern (label match, plus — for adapters that populate an assignment signal — whether the issue remains assigned to this worker).
- **FR-013**: `Orchestrator.reconcile_issue_state/4` and `Orchestrator.reconcile_blocked_issue_state/4` MUST consult only the continuation/routing concern (FR-012), never `dispatchable`, when deciding whether to terminate a running agent or release a held block for an issue Symphony already has running/blocked state for.
- **FR-014**: `AgentRunner.continue_with_issue?/2` MUST consult only the continuation/routing concern (FR-012), never `dispatchable`, when deciding whether a multi-turn agent run continues.
- **FR-015**: The admission-path usage in `Orchestrator.candidate_issue?/3` (reached only via `should_dispatch_issue?/4`, already scoped to issues not already running, claimed, or blocked) MUST remain gated on `dispatchable` and MUST NOT be altered by FR-012's split.
- **FR-016**: This feature's fix (FR-012–FR-015) MUST preserve every existing adapter's real current continuation behavior, verified directly rather than assumed — in particular Linear's existing assignee-reassignment continuation stop and Asana's existing `completed`-vs-section-name handling — or, if a genuine incompatibility is found, MUST document it as an explicit, deliberate trade-off rather than silently dropping it.
- **FR-017**: `acquire_issue/2`/`release_issue/2` MUST be scoped exclusively to Bindle's claim/release CLI calls — MUST NOT read or write any lifecycle-state field, and MUST NOT be satisfiable by a raw database mutation.
- **FR-018**: Any lifecycle-state mutation a coding-agent session performs against a Bindle-managed item MUST flow through Symphony's existing agent-invoked, host-executed tracker-write boundary (`agent_tool_specs/0`/`execute_agent_tool/3`), scoped to the one work item bound to that session — mirroring the standalone local tracker's `local_tracker_set_state` scope restriction — and MUST NOT introduce a new orchestrator-owned API for this category of write.
- **FR-019**: Selecting `tracker.kind: bindle` MUST be a distinct, explicit configuration choice, mutually exclusive with every other `tracker.kind` value, consistent with the existing single-active-work-tracking-source model (`001-local-tracker-multi-agent` FR-012).
- **FR-020**: This feature MUST NOT reconstruct, cache, or become authoritative for any Bindle dependency/blocking graph, milestone concept, evidence-validation logic, or reconciliation policy inside Symphony.

### Key Entities

- **Bindle-Facing Schedulable Projection** (existing, published by Bindle — read, not created, by this feature): the physically separate, read-only SQLite artifact at the operator-configured path (conventionally `.bindle-work/symphony-projection.sqlite3` inside the configured Bindle repository), containing one `task_projection` row per top-level schedulable Bindle task, with a schema-version marker this feature's adapter must validate before use.
- **Bindle-Backed Tracker Adapter** (new, this feature): `SymphonyElixir.Bindle.Adapter`, structurally analogous to the existing per-provider adapters, reading only the projection above and calling only Bindle's supported CLI write surface for acquisition/release.
- **Tracker Acquisition/Release Seam** (new, this feature, on the existing `Tracker` behaviour): the `acquire_issue/2`/`release_issue/2` optional callback pair and its orchestrator call sites.
- **Bindle CLI Write Surface** (existing, external to Symphony, consumed by this feature): the `bindle work claim/release/done` commands, invoked as an external process with `cwd` set to the target Bindle repository, whose exit code and output this feature's adapter interprets but never bypasses with a direct database write.
- **Owner Identity** (new, this feature): a stable, deployment-local identifier persisted across restarts, supplied as every claim/release call's `--owner` argument, and used to scope startup-time stale-claim reconciliation to this deployment's own claims.
- **Continuation/Routing Concern** (new split of an existing concept, this feature): the subset of `Tracker.Issue`'s existing fields (labels, and — for adapters that populate it — an assignment signal) that governs whether Symphony continues an already-dispatched issue, now explicitly distinct from the admission concern (`dispatchable`).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can configure `tracker.kind: bindle` against a real Bindle repository and have Symphony successfully poll, dispatch, and run a coding-agent session against a dispatchable Bindle task through the unmodified orchestrator/agent-runner path.
- **SC-002**: In a test seeding two concurrent acquisition attempts against the same Bindle task, exactly one succeeds and the other is treated as unavailable — never both, never neither, never a crash.
- **SC-003**: In a test driving a running or blocked issue's projection to `dispatchable: false` with unchanged active state and unchanged routing, the running agent is not terminated and the held block is not released — verified directly against `Orchestrator.reconcile_issue_state/4`, `Orchestrator.reconcile_blocked_issue_state/4`, and `AgentRunner.continue_with_issue?/2`.
- **SC-004**: Every existing adapter's own test suite (dispatch, release, continuation, including Linear's assignee-reassignment stop and Asana's completed-vs-section-name handling) passes unmodified in outcome after this feature's changes.
- **SC-005**: No test, code path, or module in this feature reads or interprets a Bindle dependency/blocking, milestone, or evidence table/column, or calls anything other than the `bindle work claim/release/done` CLI verbs to mutate Bindle-owned state.
- **SC-006**: A crash simulated between a successful acquisition and the corresponding work being fully underway is recovered by this deployment's own startup-time reconciliation releasing the stale claim, without manual operator intervention.

## Out of Scope / Non-Goals

- Bindle's own internal schema, storage engine, dependency/claims/evidence model, reconciliation logic, or the mechanics of publishing the projection artifact — entirely Bindle's own project (per `002-bindle-integration`).
- Mechanical evidence verification of any kind — remains entirely inside Bindle (`002-bindle-integration` FR-012, Non-Goals).
- Semantic completion/correctness judgment automation — remains human-resolved (`002-bindle-integration` FR-013).
- `bindle symphony init/start/status` or any other convenience/UX wrapper tooling around this integration.
- Any migration or synchronization mechanism between Symphony's standalone local tracker and the Bindle-backed tracker — the two remain fully independent, non-interacting stores (`002-bindle-integration` User Story 4).
- Multi-instance Symphony deployment support beyond what Bindle's own claim arbitration already guarantees for concurrent acquisition attempts — this feature relies on that guarantee but does not build new multi-instance orchestration.
- Reopening or rewriting `001-local-tracker-multi-agent` or `002-bindle-integration`'s frozen specifications.

## Assumptions

- `002-bindle-integration`'s frozen contract (FR-001–FR-017, its Key Entities, and its Assumptions) is authoritative for this feature's architectural boundary; this feature implements it rather than re-deriving it, correcting only where re-verification against Bindle's and Symphony's actual current code finds the prior contract's grounding stale.
- Bindle's published projection schema (`task_projection` table: `id`, `identifier`, `title`, `description`, `status`, `dispatchable`, `created_at`; `PRAGMA user_version = 1`) and its `bindle work claim/release/done` CLI contract (exit-code/stderr convention, `cwd`-scoped ledger resolution, no `--repo` flag, no JSON output) are as directly verified against Bindle's actual current implementation (`~/Developer/bindle`, HEAD `dace8f6`) during this feature's grounding pass; a future incompatible Bindle-side schema or CLI change is handled by this feature's fail-loud version check (FR-002), not by this feature anticipating it further.
- `exqlite` is already a Symphony dependency (`mix.lock`, `~> 0.30`, currently resolving `0.40.0`); this feature reuses it rather than adding a new SQLite library, unless implementation-stage investigation finds it unsuitable for read-only-mode access, in which case that finding is documented at the planning stage.
- A stable owner-identity string and a startup-time stale-claim reconciliation pass are new Symphony-side state and behavior this feature must design and build; `002-bindle-integration` explicitly left both as open design questions for this feature's planning stage, not as already-solved edge cases.
- The concrete config field names for `tracker.kind: bindle`'s provider settings (projection path, Bindle repository path, CLI binary name/path, owner-identity storage location) are an implementation decision for this feature's planning stage, following the existing per-adapter `tracker.provider` convention.
- This feature's admission/continuation fix (FR-012–FR-016) is a generic correction to Symphony's own reconciliation semantics, required for every tracker, not a Bindle-specific carve-out — consistent with `002-bindle-integration` FR-017's own framing.
