# Implementation Plan: Bindle-Backed Tracker Adapter Implementation

**Branch**: `003-bindle-tracker-adapter` (Spec Kit feature identifier only; work stays on `development` per the fork's workflow — see `001-local-tracker-multi-agent`/`002-bindle-integration`) | **Date**: 2026-08-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-bindle-tracker-adapter/spec.md`

**Correction pass (2026-08-27)**: this plan's Technical Context, Constitution Check, and Project Structure
were revised after a review pass found the first draft's local claims-ledger design not crash-safe, its
acquisition call inventing an untruthful `--worktree` value, and an unscoped `done`/agent-tool addition
that crossed `002-bindle-integration` User Story 5's semantic-judgment boundary. See `research.md` R4–R7,
R12–R15 and `spec.md`'s Correction Note for the full grounding.

**Second correction pass (2026-08-27, same day)**: this plan's Technical Context, Constitution Check, and
Project Structure were revised again after `002-bindle-integration`'s own FR-013 correction (task `done` vs.
milestone `accepted`) and newly-verified Symphony runtime facts required five further changes: (1) the
`bindle/agent_tool.ex` module removed by the first correction pass is **restored**, narrowly, as the one
FR-025/FR-026 task-completion tool; (2) `spawn_issue_on_worker_host/5`'s acquisition call and
`retry_candidate_issue?/2`'s re-validation now branch on whether the issue is already in `state.claimed`
(fresh-admission vs. continuation-retry, FR-016/FR-024); (3) `tracker/issue.ex`'s planned `routed_by_assignment`
field is renamed `continuation_allowed` and `asana/client.ex` is added to the modified-files list to populate
it; (4) `bindle/cli.ex` gains `done/3` and `publish/2`, called only from the agent tool, never from the
claim/release seam; (5) the startup reconciliation sweep gains bounded per-id retry using the existing
`schedule_issue_retry/4` timer primitive. See `research.md`'s new entries and `spec.md`'s second Correction
Note for the full grounding.

## Summary

Implement the Bindle-backed `Tracker` adapter and the two generic runtime seams `002-bindle-integration`
specified but deferred: (1) a new `SymphonyElixir.Bindle.Adapter` reading Bindle's published, read-only,
schema-versioned SQLite projection and mapping rows onto `Tracker.Issue`; (2) a new, optional
`acquire_issue/2`/`release_issue/2` `Tracker` callback pair, wired into the orchestrator's existing
dispatch/release call sites, whose Bindle implementation shells out to Bindle's own `bindle work
claim`/`release` CLI (never `done`, never a raw database write) and correctly distinguishes a fresh-admission
acquisition from a continuation retry of an issue already held in `state.claimed` (FR-016/FR-024, never
re-acquiring in the latter case); (3) a required, generic correction splitting `Tracker.Issue`'s combined
admission+routing predicate so a successfully-claimed item is never preempted merely because its
`dispatchable` fact naturally flips to `false` once claimed, using a new provider-neutral `continuation_allowed`
field (not the Linear-specific `routed_by_assignment` the first draft proposed) that both Linear and Asana
populate; and (4) one narrow, agent-invoked, session-scoped task-completion tool (spec.md FR-025–FR-027,
restored after `002-bindle-integration` FR-013's correction) that calls `bindle work done <id>` for the
session's own bound task only, followed by a best-effort `bindle work publish`. All four land as additive
changes on top of the existing per-adapter/orchestrator architecture; no existing adapter's behavior changes,
and no milestone-acceptance, evidence, or dependency-graph capability is added anywhere (spec.md User Story 5).

## Technical Context

**Language/Version**: Elixir `~> 1.19` (OTP 28), via `mise` — unchanged.

**Primary Dependencies**: `exqlite ~> 0.30` for read-only SQLite access to the published projection.
**Correction (implementation-stage)**: every prior draft of this document asserted `exqlite` was "already
present in `mix.lock`" — verified directly against `elixir/mix.exs`/`mix.lock` during implementation that
this was never true; it was added here as a new dependency (resolves to `0.40.0`, the version already
assumed throughout this feature's artifacts), via its low-level `Exqlite.Sqlite3` API, not the Ecto
adapter. No other new dependency; the Bindle CLI is invoked via `System.cmd/3`, no HTTP/JSON client needed
(the CLI has no JSON output mode).

**Storage**: Reads only Bindle's externally-published, read-only `symphony-projection.sqlite3` (via
`exqlite`, opened with a read-only URI). The orchestrator-owned claim/release seam writes only through the
external `bindle` CLI process (`claim`/`release` only — never `done`/`publish`) — Symphony never opens a
write-capable SQLite connection to any Bindle-owned file. Separately, the agent-invoked task-completion tool
(FR-025–FR-027) writes through the same `bindle` CLI process using `done`/`publish` only, on the same
`SymphonyElixir.Bindle.Cli` wrapper module but never through the claim/release seam's own code path. New
local Symphony-side state: a persisted owner-identity file only. Crash recovery is a startup-time
projection-enumeration + owner-scoped release sweep with bounded per-id retry on individual failure
(FR-029), not a local ledger (data-model.md §6, research.md R5) — there is no local record of which tasks
this deployment previously claimed.

**Testing**: `mix test` / `make all`, unchanged toolchain. New tests: a real temporary SQLite fixture
matching Bindle's actual `task_projection` schema (row mapping, schema-version validation, read-only
enforcement, fail-loud on a structurally invalid row per FR-003); an injectable `:bindle_cli_module` seam
(mirroring `gitlab/adapter.ex`'s existing `:gitlab_client_module` injection pattern,
`elixir/lib/symphony_elixir/gitlab/adapter.ex:47-48`) so the CLI boundary is testable without an installed
`bindle` binary; orchestrator/agent-runner integration tests for the admission-vs-continuation fix,
covering every existing adapter's continuation behavior (Linear reassignment stop, Asana `continuation_allowed`
population from `task["completed"]`) explicitly, not just the new adapter's own; a dedicated test for the
acquire-success/spawn-failure compensation path (FR-008/SC-006), for the fresh-admission-vs-continuation-retry
acquisition-gating split (FR-016/FR-024/SC-008), for the agent-invoked task-completion tool's session-scoping
and `done`-then-`publish` sequencing including a publish-failure-after-done case (FR-025–FR-027/SC-009), and
for startup-time reconciliation's projection-enumeration release sweep including its bounded per-id retry on
an individual release failure (FR-012/FR-029/SC-007).

**Target Platform**: Existing Burrito-packaged single-binary targets — unchanged; the `bindle` CLI is an
external, separately-installed binary this feature invokes via `System.cmd/3`, not vendored or packaged.

**Project Type**: Single Elixir OTP application — unchanged. Adds one new adapter package
(`lib/symphony_elixir/bindle/`) following the existing per-adapter convention; extends `tracker.ex`,
`tracker/issue.ex`, `orchestrator.ex`, `agent_runner.ex`, `linear/client.ex`, `asana/client.ex`, and
`config/schema.ex` with narrow, additive changes.

**Performance Goals**: N/A beyond existing polling cadence — the projection read is a local SQLite query;
the CLI claim/release calls are synchronous subprocess invocations on the existing dispatch/release path,
same cost class as any other adapter's existing HTTP calls (GitHub/GitLab/Jira/Linear/Asana already make
a network call at analogous points).

**Constraints**: Every requirement in `002-bindle-integration` (FR-001–FR-017, including FR-013 as corrected)
is a hard constraint on this plan, not merely context — in particular: read-only projection access only
(FR-002), no Bindle vocabulary in orchestrator-facing code (FR-004), the orchestrator-owned claim/release
seam scoped only to Bindle's supported `claim`/`release` CLI verbs — never `done`/`publish` (FR-016/FR-018),
and the admission-vs-continuation invariant (FR-017) applied generically, not as a Bindle-specific branch.
This feature's own `spec.md` FR-019/FR-023 additionally constrain this plan: no **orchestrator-owned** tool
may be added for Bindle lifecycle mutation of any kind, and no tool of any kind may touch milestone
review/acceptance, dependency/blocking, or evidence state — but FR-025–FR-027 do authorize, and this plan
does build, one narrow, agent-invoked, session-scoped exception: a task-completion tool restricted to the
session's own bound task, per `002-bindle-integration` FR-013 as corrected.

**Scale/Scope**: One new adapter package (6 modules — adapter, projection reader, CLI wrapper, owner
identity, startup reconciliation logic, and the restored agent-tool module scoped to task completion only;
no claims-ledger module, see Correction Note above), one new optional callback pair on `tracker.ex`, one
split predicate on `tracker/issue.ex` plus its `continuation_allowed` field, targeted changes at 6 call
sites across `orchestrator.ex`/`agent_runner.ex` (including the acquire-success/spawn-failure compensation
path, FR-008, and the fresh-admission-vs-continuation-retry acquisition gating, FR-016/FR-024), one targeted
addition to `asana/client.ex` to populate `continuation_allowed` (FR-013/FR-017), one new
`resolve_tracker_provider("bindle", ...)` clause in `config/schema.ex`, and the corresponding test suite.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Checked against `.specify/memory/constitution.md` v1.0.0:

- **I. Inherit Upstream First** — PASS. The Bindle adapter is a new, additive `Tracker` implementation
  following the exact existing adapter contract; it does not replace or bypass the orchestrator's existing
  dispatch/reconciliation machinery. The admission/continuation fix corrects a real defect in that existing
  machinery rather than replacing it (see II below for why this is justified, not a deviation).

- **II. Minimize Fork Delta** — PASS, with the same two deliberate, justified exceptions `002-bindle-
  integration`'s Constitution Check already accepted at the specification level, now actually built:
  (a) the `acquire_issue/2`/`release_issue/2` optional callback pair on `Tracker` — non-zero shared-code
  addition, but `@optional_callbacks`-guarded to a complete no-op for all six existing adapters, and
  narrowly scoped to two call sites; (b) the `Issue.routable?/2` split and its three continuation call-site
  corrections (`reconcile_issue_state/4`, `reconcile_blocked_issue_state/4`, `continue_with_issue?/2`) —
  a verified, load-bearing correctness fix (without it, FR-015's claim-then-dispatch sequence causes
  self-preemption on the very next poll), not speculative generalization, and its scope is fixed at exactly
  these three call sites, explicitly leaving `candidate_issue?/3` (the legitimate admission-path usage)
  untouched.

- **III. Preserve Upstream Compatibility** — PASS. No existing deployment's configuration or behavior
  changes: `tracker.kind` values other than the new `"bindle"` are unaffected; the callback pair is a no-op
  for every existing adapter (verified by User Story 4's regression tests); the admission/continuation fix
  is required to change zero observable behavior for any adapter except correcting the one genuine defect
  (self-preemption after claim) that only manifests for a durable-claim-aware tracker — no adapter existing
  today implements `acquire_issue/2`, so no existing adapter's continuation behavior can regress from that
  specific defect; User Story 4 additionally verifies each adapter's *other* continuation behaviors
  (Linear/Asana) are unaffected by the predicate split itself.

- **IV. Specification Before Implementation** — PASS. `002-bindle-integration`'s frozen spec is treated as
  authoritative for the architectural boundary; this plan and its tasks implement it, and this feature's
  own `spec.md` (reviewed before this plan) is authoritative for this feature's own scope.

- **V. Avoid Unnecessary Abstraction** — PASS: this correction pass removes a local claims-ledger module
  entirely (it was not crash-safe and was unnecessary state — Bindle's own safe-release guarantee makes a
  projection-enumeration sweep sufficient, research.md R5). The second correction pass **restores** one
  agent-invoked task-completion tool (spec.md FR-025–FR-027) — this is not new abstraction; it is the
  smallest possible surface satisfying `002-bindle-integration` FR-013 as corrected (one tool, one target id
  resolved only from session state, two CLI calls), narrower than the local tracker's own
  `local_tracker_set_state` in scope. No new orchestration framework, lifecycle ontology, or generic plugin
  system is introduced. The owner-identity mechanism is the minimum new state needed to satisfy
  FR-011/FR-012, not a general identity system. The startup-reconciliation bounded-retry fix (FR-029) reuses
  the existing `schedule_issue_retry/4` timer primitive rather than adding a new one.

- **VI. Preserve Execution Boundaries** — PASS, and central to this plan: the Bindle adapter and the
  claim/release seam never read or interpret Bindle's dependency/blocking, milestone, or evidence state;
  `acquire_issue/2`/`release_issue/2` are scoped exclusively to the claim/release CLI calls, never `done`/
  `publish` (FR-018). The restored task-completion tool (FR-025–FR-027) is scoped exclusively to `bindle
  work done`/`publish` for the one task bound to the requesting session — it cannot reach milestone
  review/acceptance, evidence, or dependency/blocking state, and shares no code path with the
  orchestrator-owned claim/release seam beyond the `Bindle.Cli` wrapper module both call into. This is the
  one narrow exception `002-bindle-integration` FR-013 (as corrected) explicitly authorizes; every other
  boundary this principle protects is unchanged from the first correction pass.

- **VII. Verify Fork Behavior Without Regressing Upstream** — PASS. This plan requires focused new tests
  for every new behavior (adapter mapping, schema-version failure, claim/release arbitration, admission-
  vs-continuation) plus explicit re-verification that every existing adapter's own dispatch/release/
  continuation test coverage passes unmodified in outcome (User Story 4, SC-004).

No violations requiring the Complexity Tracking table — both Constitution II exceptions are the same ones
`002-bindle-integration`'s own Constitution Check already justified at the specification level; this plan
does not introduce a new exception beyond what that frozen spec already accepted.

### Post-Design Re-Check (after Phase 1)

Re-evaluated against `research.md`, `data-model.md`, and `contracts/bindle-tracker-adapter.md` as actually
written.

- research.md confirms `exqlite` supports SQLite's `mode: :readonly` open flag directly (`Exqlite.Sqlite3.open/2`)
  — no workaround needed to satisfy FR-002's read-only requirement. It is a new dependency, not an
  already-present one (corrected above, Technical Context) — a small, justified addition given no SQLite
  library existed in this project before this feature. **I/II/V still PASS**: II's "minimize fork delta"
  is about shared orchestration code, not dependency count, and V's "avoid unnecessary abstraction" is
  satisfied since `exqlite`'s low-level `Sqlite3` API is used directly with no Ecto Repo/migration
  machinery added on top of it.
- data-model.md's Owner Identity (§5) and Startup Reconciliation (§6) are confirmed as the minimum new
  state needed — a single persisted string and a stateless, blind projection-enumeration release sweep,
  not a new subsystem or a local ledger. **V still PASS**, and more cleanly than the Constitution Check
  above anticipated, since the correction pass removed a stateful ledger design in favor of this simpler
  one.
- contracts/bindle-tracker-adapter.md's exact `System.cmd/3` invocation shape (args, `cd:`, exit-code/
  stderr interpretation — `claim`/`release` on the orchestrator-owned seam, `done`/`publish` on the
  agent-tool's own separate call path, never crossed) was verified directly against Bindle's actual CLI
  argument parsing, exit-code convention, and `task-write-surface.md` contract, not assumed. **VI still
  PASS** — no raw database write path exists anywhere in the design, and no milestone-acceptance,
  evidence, or dependency-graph capability of any kind is introduced (FR-018/FR-019/FR-023).
- data-model.md §8/§9's release-callback shape (id-based, not `Issue.t()`-based) and single-call-site
  consolidation, and the acquire-success/spawn-failure compensation path, were verified directly against
  `orchestrator.ex`'s actual `terminate_running_issue/3`/`release_issue_claim/2`/
  `spawn_issue_on_worker_host/5` call sites, not assumed correct by symmetry with `acquire_issue/2`.
  **II/VI still PASS** — this is a correctness fix at exactly the call sites that need it, not a new
  abstraction.
- data-model.md §9's fresh-admission-vs-continuation-retry split (FR-016/FR-024) was verified directly
  against `orchestrator.ex`'s actual shared `refresh_issue_for_dispatch/1`/`retry_candidate_issue?/2` control
  flow, not assumed safe by symmetry with the acquire-success/spawn-failure path — the two races are
  distinct (one is about a claim never acquired, the other about a claim already held) and require distinct
  fixes. **I/II still PASS** — this narrows an existing shared predicate's behavior at exactly the point it
  needs to branch, introducing no new call sites beyond the ones FR-006/FR-016 already named.
- data-model.md's Continuation/Routing field (§3, `continuation_allowed`) and its Asana population (§9a)
  were verified directly against `asana/client.ex`'s actual, independent `state`/`dispatchable` computation,
  closing a real gap rather than carrying forward an unverified assumption that label match already covered
  it. **VII still PASS** — User Story 4's regression tests now cover this explicitly (SC-010).
- No Constitution gate FAILs as a result of Phase 1 design; Complexity Tracking table remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/003-bindle-tracker-adapter/
├── plan.md                              # This file (/speckit-plan command output)
├── research.md                          # Phase 0 output
├── data-model.md                        # Phase 1 output
├── quickstart.md                        # Phase 1 output
├── contracts/
│   └── bindle-tracker-adapter.md        # Phase 1 output — adapter/CLI/config contract
└── checklists/
    └── requirements.md                  # Spec quality checklist (/speckit-specify output)
```

### Source Code (repository root)

```text
elixir/
├── lib/symphony_elixir/
│   ├── tracker.ex                    # MODIFIED: +acquire_issue/2, +release_issue(issue_id, opts) (@optional_callbacks)
│   ├── tracker/issue.ex              # MODIFIED: split routable?/2 into dispatchable?/1 + routed?/2;
│   │                                 #   +continuation_allowed field (default true)
│   ├── orchestrator.ex               # MODIFIED: call acquire_issue/2 before spawn, only in fresh-admission
│   │                                 #   mode (issue not already in state.claimed, FR-016/FR-024) — a
│   │                                 #   continuation retry of an issue already in state.claimed skips
│   │                                 #   straight to Task.Supervisor.start_child/2, reusing the held claim;
│   │                                 #   on spawn failure after a successful acquisition, call
│   │                                 #   release_issue/2 (via release_issue_claim/2) before scheduling the
│   │                                 #   retry (FR-008); terminate_running_issue/3's found-running-entry
│   │                                 #   branch delegates its state-clearing to release_issue_claim/2
│   │                                 #   instead of duplicating it inline, so release_issue/2 fires from
│   │                                 #   exactly one place (FR-020/FR-021); reconcile_issue_state/4 and
│   │                                 #   reconcile_blocked_issue_state/4 use routed?/2, not dispatchable;
│   │                                 #   retry_candidate_issue?/2 re-validation branches on state.claimed
│   │                                 #   membership the same way (FR-016); +startup-time
│   │                                 #   reconcile_stale_claims/1 call before normal polling, with bounded
│   │                                 #   per-id retry on an individual release failure (FR-029), reusing
│   │                                 #   schedule_issue_retry/4's timer primitive
│   ├── agent_runner.ex               # MODIFIED: continue_with_issue?/2 uses routed?/2, not dispatchable
│   ├── config/schema.ex              # MODIFIED: +resolve_tracker_provider("bindle", ...) — repo_path
│   │                                 #   defaults to Config.workflow_dir(), projection path defaults
│   │                                 #   relative to repo_path (research.md R15)
│   ├── linear/client.ex              # MODIFIED (if needed): populate continuation_allowed with Linear's
│   │                                 #   existing still-assigned-to-this-worker computation, preserving its
│   │                                 #   reassignment-stop behavior under the new split predicate
│   ├── asana/client.ex               # MODIFIED (new in this correction pass): populate continuation_allowed
│   │                                 #   from task["completed"] == false, independent of section/state —
│   │                                 #   closes the completed-vs-section-name gap (FR-017/SC-010)
│   └── bindle/                       # NEW package, mirrors local/'s shape — agent_tool.ex restored
│       │                             #   (narrowed to task-completion only, FR-025/FR-026); no
│       │                             #   claims_ledger.ex (removed in the first correction pass; see
│       │                             #   Correction Notes above)
│       ├── adapter.ex                # @behaviour SymphonyElixir.Tracker; delegates reads to Projection,
│       │                             #   acquire/release to Cli, agent_tool_specs/0 to AgentTool
│       ├── agent_tool.ex             # RESTORED, narrowly: one tool ("bindle_mark_task_done" or similar)
│       │                             #   resolving its target exclusively from opts[:issue].id (never a
│       │                             #   model-supplied id); calls Cli.done/3 then Cli.publish/2 (FR-025–
│       │                             #   FR-027); exposes no milestone/evidence/dependency operation
│       ├── projection.ex             # Opens/validates/queries the read-only SQLite projection;
│       │                             #   fetch_by_states/2/fetch_by_ids/2 fail loud on a structurally
│       │                             #   invalid row (FR-003); +list_ids/1 for startup reconciliation
│       ├── cli.ex                    # Thin System.cmd/3 wrapper over `bindle work claim`/`release`/`done`/
│       │                             #   `publish`; claim/4 supplies no worktree/branch; done/3 and
│       │                             #   publish/2 take no --owner argument (FR-025–FR-028); only
│       │                             #   agent_tool.ex calls done/3 and publish/2 — adapter.ex's
│       │                             #   acquire_issue/2/release_issue/2 never do
│       └── owner.ex                  # Persisted, stable deployment-local owner-identity string; fails
│                                     #   loud on corrupt/empty existing state rather than regenerating
├── mix.exs / mix.lock                # UNCHANGED (exqlite already present)
└── test/symphony_elixir/
    ├── bindle_adapter_test.exs           # NEW: projection→Issue mapping, schema-version failure, RO
    │                                     #   enforcement, fail-loud on a malformed row (FR-003)
    ├── bindle_projection_test.exs        # NEW: projection open/validate/query/list_ids unit tests
    ├── bindle_cli_test.exs               # NEW: CLI arg/exit-code/stderr interpretation, cwd scoping,
    │                                     #   claim/release/done/publish verb construction, no --owner on
    │                                     #   done/publish
    ├── bindle_agent_tool_test.exs        # RESTORED (narrowed): session-scoped target resolution (rejects/
    │                                     #   ignores any model-supplied id), done-then-publish sequencing,
    │                                     #   publish-failure-after-done does not retry done (FR-025–FR-027/
    │                                     #   SC-009)
    ├── bindle_owner_test.exs             # NEW: owner-identity persistence + fail-loud-on-corrupt
    ├── bindle_orchestrator_integration_test.exs  # NEW: acquire-before-spawn in fresh-admission mode only
    │                                             #   (no worktree/branch supplied), no re-acquire on a
    │                                             #   continuation retry (FR-016/FR-024/SC-008),
    │                                             #   release-at-existing-points, acquire-success/
    │                                             #   spawn-failure compensation (FR-008/SC-006),
    │                                             #   single-call-site (no double-release, FR-021),
    │                                             #   startup-time projection-enumeration reconciliation
    │                                             #   including bounded per-id retry (FR-012/FR-029/SC-007)
    ├── tracker_issue_test.exs            # NEW or EXTENDED: dispatchable?/1 vs routed?/2 split,
    │                                     #   continuation_allowed default/override
    ├── tracker_test.exs                  # NEW or EXTENDED: acquire_issue/2/release_issue/2 no-op defaults
    ├── asana_adapter_test.exs            # EXTENDED: continuation_allowed population from task["completed"]
    │                                     #   independent of section/state (SC-010)
    ├── orchestrator_status_test.exs      # EXTENDED: admission-vs-continuation regression (SC-003)
    └── core_test.exs                     # EXTENDED: existing-adapter regression (SC-004)
```

**Structure Decision**: Single-project Elixir layout, unchanged. The Bindle adapter is one additive
package under `lib/symphony_elixir/bindle/`, registered in `Tracker.@adapters` exactly as `local` was in
`001-local-tracker-multi-agent`. All other source changes are narrow, targeted edits to existing modules
at the specific call sites `spec.md`'s FRs name — no new top-level directory, no new orchestration layer.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations. Table intentionally omitted.
