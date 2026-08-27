# Implementation Plan: Bindle-Backed Work Tracking Through a Narrow Schedulable Projection

**Branch**: `002-bindle-integration` (Spec Kit feature identifier only; work stays on `development` per the fork's workflow — see `001-local-tracker-multi-agent`) | **Date**: 2026-08-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-bindle-integration/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

This feature is an architecture/contract specification, not a runtime capability — it authorizes no source
code change of its own. It fixes the ownership boundary between Symphony and a future Bindle integration —
Bindle owns its durable implementation ledger; Symphony consumes only a narrow, Bindle-owned schedulable
projection artifact through its existing `Tracker` adapter boundary, producing the existing `Tracker.Issue`
shape unchanged, plus one new narrow acquisition/release seam for real-time dispatch arbitration — and it
defers every Bindle-side and transport-level decision (Bindle's projection-publish mechanics, config field
names, exact `tracker.kind` value, and the acquisition seam's own implementation) to the planning stage of a
future, separate implementation feature that builds the actual Bindle-backed adapter and the `Tracker`
behaviour/orchestrator changes FR-015 requires.

**Correction to this plan's prior framing**: an earlier draft of this plan stated its only in-scope change
was a one-file moduledoc correction to `elixir/lib/symphony_elixir/local/store.ex` (spec FR-014), described
at the time as "currently uncommitted." `development`'s own current copy of that file — JSON-file-backed —
was verified directly, during this feature's correction pass, to carry no stale language needing correction
in the first place (research.md R8). This plan therefore authorizes **zero** source code changes of its own;
FR-014 is satisfied by `development`'s already-existing code, not by work this plan performs.

**Repository hygiene (resolved)**: An earlier draft of this plan found the JSON-to-SQLite conversion of
`Local.Store`/`Local.Adapter` (commit `92e137e`) sharing this branch's history with this feature's own spec
commit (`93f60ca`) — two disjoint, unrelated changes (verified via full diff review: entirely disjoint file
sets; the only mention of "Bindle" anywhere in the SQLite-conversion commit's diff is `store.ex`'s moduledoc,
which correctly disclaims any Bindle relationship) — and recommended splitting the conversion onto its own
branch before any force-push. **That separation has since been performed**: `92e137e` now lives on branch
`local-tracker-sqlite` and is no longer part of `development`'s history (verified: `git merge-base
--is-ancestor 92e137e HEAD` fails against current `development`). `development`'s standalone local tracker
is therefore JSON-file-backed, not SQLite-backed, as of this specification's correction pass — every other
reference to its persistence mechanism throughout this feature's artifacts has been corrected to
persistence-neutral language accordingly, since the storage format is irrelevant to this integration
boundary and may change again independently of this feature without requiring another such correction pass.

## Technical Context

**Language/Version**: Elixir `~> 1.19` (OTP 28), via `mise` — unchanged. This feature makes no code change
of its own (see Summary's correction above).

**Primary Dependencies**: None added or removed. This feature does not touch `mix.exs`/`mix.lock`. A future
Bindle-backed adapter's dependencies (if any), and the new `Tracker` behaviour acquisition/release callback
pair FR-015 requires, are out of scope for this plan and belong to the eventual implementation feature.

**Storage**: N/A for this feature's own scope. Symphony's standalone local tracker storage (`Local.Store`,
`001-local-tracker-multi-agent` — currently JSON-file-backed in `development`; its concrete persistence
mechanism is irrelevant to and unconstrained by this feature, see spec User Story 4) is unmodified in shape
or behavior. The published Bindle-facing projection artifact's physical shape (a separate, read-only,
schema-versioned SQLite file that Symphony's future adapter opens in SQLite's own read-only mode — spec
FR-002, research.md R1) is now fixed by this feature at the specification level, but producing it is
Bindle's own implementation, entirely outside this repository.

**Testing**: `mix test` / `make all`, unchanged toolchain. This feature makes no code change, so no new test
is required or possible at this feature's own scope. The eventual implementation feature that builds the
`Tracker` behaviour acquisition/release callback pair (FR-015) and the Bindle-backed adapter itself will need
new tests for: the callback pair's optional/no-op behavior on every existing adapter, the orchestrator's
skip-on-non-success acquisition handling, and (once designed) the crash-recovery reconciliation logic
research.md R10 identifies as a required, currently-unresolved gap — none of that is testable at this
feature's specification-only scope.

**Target Platform**: Existing Burrito-packaged single-binary targets — unchanged; this feature does not
touch packaging.

**Project Type**: Single Elixir OTP application — unchanged. This feature adds no new module, package, or
directory. A future Bindle-backed adapter (out of scope here) would follow the existing
`lib/symphony_elixir/local/`-shaped package convention when it is eventually built.

**Performance Goals**: N/A — no runtime behavior is introduced or changed by this feature.

**Constraints**: This feature's own constraint is definitional, not runtime: any future Bindle-backed
adapter design MUST NOT require shared mutable database ownership between Symphony and Bindle, a JSON
synchronization layer, Git-backed coordination state, a hosted control plane, or other new infrastructure
not demonstrably required by spec FR-001–FR-014 (see Non-Goals). This plan enforces that constraint by
scope (deferring all such decisions) rather than by writing code against it.

**Scale/Scope**: One specification, one plan (this document) with its Phase 0/1 design artifacts. Zero new
modules, zero source changes. The eventual Bindle-backed `Tracker` adapter implementation, the new
acquisition/release callback pair (FR-015), and the orchestrator wiring/crash-recovery reconciliation it
requires are explicitly future work under a separate implementation feature, not part of this plan's scope
or task list.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Checked against `.specify/memory/constitution.md` v1.0.0:

- **I. Inherit Upstream First** — PASS. This feature changes zero orchestration, scheduler, dispatcher, or
  agent-runner behavior itself; it specifies a future adapter's contract, and one future `Tracker` behaviour
  addition (FR-015), in terms of Symphony's existing adapter-registration pattern.
- **II. Minimize Fork Delta** — PASS, with one deliberate, justified exception noted rather than hidden:
  this specification requires one new narrow, optional, adapter-agnostic callback pair on the `Tracker`
  behaviour (FR-015) — a genuine, non-zero addition to shared orchestration code, not merely a new adapter
  module. It is justified because it is a verified, load-bearing correctness requirement (Bindle's own
  durable claim mechanism requires it, research.md R10), not speculative flexibility: it is optional,
  defaults to a complete no-op for every existing adapter, and its scope is fixed narrowly by this
  specification rather than left open-ended. The future Bindle-backed adapter itself remains scoped, when
  eventually built, as one additive adapter (mirroring `local`/`github`/`gitlab`/`jira`/`linear`/`asana`).
- **III. Preserve Upstream Compatibility** — PASS. No existing deployment's configuration, behavior, or
  observable output changes as a result of this feature; FR-015's callback pair is a no-op for every adapter
  existing today, verified explicitly as an acceptance scenario (User Story 2, Acceptance Scenario 4).
- **IV. Specification Before Implementation** — PASS, and this is this feature's entire purpose: it exists
  specifically to put a reviewed specification in place *before* any Bindle-backed adapter implementation,
  or the `Tracker` behaviour/orchestrator change FR-015 requires, is attempted.
- **V. Avoid Unnecessary Abstraction** — PASS. The spec explicitly rejects inventing Bindle-internal
  concepts inside Symphony (claims, evidence, reconciliation, milestones, dependency-graph internals —
  FR-004, FR-011) and fixes the projection transport's physical shape only as far as verified necessary
  (research.md R1) rather than over-specifying Bindle's own publish mechanics. FR-015's callback pair is
  deliberately generic in name and shape — no Bindle vocabulary in the `Tracker` behaviour's public contract
  — precisely to avoid the alternative of teaching the orchestrator Bindle-specific concepts directly.
- **VI. Preserve Execution Boundaries** — PASS, and central to this feature: Bindle's mechanical evidence
  verification and richer internal model stay entirely inside Bindle (FR-012); Symphony's orchestrator only
  ever sees the existing `Tracker.Issue` shape through the existing `Tracker` behaviour plus the one new
  generic seam (FR-001, FR-004, FR-015).
- **VII. Verify Fork Behavior Without Regressing Upstream** — PASS for this feature's own scope: it makes no
  code change, so there is nothing of this feature's own to regression-test. The eventual implementation
  feature building FR-015's callback pair MUST verify every existing adapter's dispatch/release behavior is
  byte-for-byte unchanged (the no-op requirement), which this plan records as a required acceptance check
  for that future feature rather than performing it here.

No violations requiring the Complexity Tracking table — FR-015's fork-delta exception is justified inline
above, not deferred to that table, since it is a specification-level requirement with no code yet to track.

### Post-Design Re-Check (after Phase 1)

Re-evaluated against `research.md`, `data-model.md`, and `contracts/bindle-schedulable-projection.md` as
actually written.

- Phase 1 design confirms (research.md R3) that a future Bindle-backed tracker must be a new, separate
  `Tracker` adapter rather than an extension of `Local.Store`. **I/II/V still PASS** under the FR-015
  exception already justified above.
- research.md R2 makes explicit, as a hard design constraint (not merely a preference), that no future
  Bindle-backed adapter may perform direct mutable writes into a Bindle-owned database file — lifecycle
  writes MUST go through a Bindle-owned write path, never a shared-database write from Symphony's OS
  process. This sharpens spec Non-Goals into an explicit rejected-alternative record without changing any
  FR. **VI still PASS.**
- No violation surfaced during design; Complexity Tracking table remains empty.

### Rework Re-Check (2026-08-27, after adversarial multi-subagent critique of the grounding pass)

A second research/critique pass — independent research forks plus adversarial critique of the projection
field shape, the transport/ownership boundary, and a proposed acquisition seam — found the prior Grounding
Re-Check's conclusions needed two corrections, not just confirmation, and surfaced one genuine gap the
original design and the grounding pass both missed:

- **R1 (transport) reversed**: the prior "favor a CLI-emitted artifact" leaning is replaced with a fixed
  requirement for a physically separate, read-only, schema-versioned SQLite artifact. The prior leaning
  rested on a misapplication of Bindle's D014 principle; no concrete blocker to a SQL-artifact transport
  survived adversarial review. **V still PASS** — this fixes the transport's *shape* only as far as verified
  necessary (the boundary-enforceability finding), not Bindle's own publish mechanics.
- **R9 (field shape) superseded**: the prior "synthesize `state` from `(terminal, eligible)`" requirement is
  replaced with a direct `status` passthrough on a purpose-built projection shape (`id, identifier, title,
  description, status, dispatchable, created_at`), since the published artifact was never going to be
  constrained to Bindle's current in-process `ProjectedWorkItem` shape once R1 requires Bindle to build a new
  artifact regardless. **I/V still PASS** — this is a simplification (removes adapter-side synthesis logic
  entirely), not new abstraction.
- **R10 (new) — durable acquisition/claim seam**: Bindle's real `claim()`/`release_claim()` mechanism
  requires a coordinator to call `claim()` before treating an item as acquired; Symphony's orchestrator today
  has no such seam, only in-memory bookkeeping with a real dispatch-time race. This produced spec FR-015/
  FR-016, and is the one Constitution II exception explicitly justified above — this gate re-check is where
  that exception was first identified and accepted, not silently introduced.
- No Constitution gate FAILs as a result of this rework; III/IV/VI/VII hold unchanged from the Post-Design
  Re-Check above. See `research.md`'s R1, R9, and R10 for full detail, and the three adversarial critique
  findings (acquisition-seam timing/crash-recovery, projection field sufficiency, transport/ownership
  boundary) that drove these corrections.

### Correction-Pass Re-Check (2026-08-27, later still — post-implementation-discipline review)

A further review, tracing R10's acquisition seam against Symphony's actual reconciliation code rather than
assuming it composes cleanly, found one more genuine defect and two consistency issues, corrected via
research.md R11 (new), R8 (corrected), and persistence-neutral language throughout this feature's artifacts.

- **R11 (new) — admission vs. continuation**: R10's acquisition seam (FR-015), once combined with today's
  reconciliation logic, contradicts it — the ordinary claim-then-dispatch sequence FR-015 requires would
  cause Symphony's own reconciliation to terminate the execution it just started, on the very next poll,
  because reconciliation currently reuses the same `dispatchable`-gated admission predicate to decide
  continuation. This produced spec FR-017, a second narrow, generic correction to Symphony's own core
  reconciliation semantics. **II still PASS, same justification pattern as FR-015/FR-016's exception above**:
  it is a verified, load-bearing correctness requirement (not speculative), it introduces no Bindle-specific
  branch, and its scope is fixed narrowly (three named continuation call sites) by this specification rather
  than left open-ended. **I/III/IV/VI/VII unaffected** — like FR-015/FR-016, this is a specification-level
  requirement with no code yet written against it; the eventual implementation feature must verify every
  existing adapter's continuation behavior is preserved or explicitly, deliberately changed (research.md
  R11's Linear and Asana compatibility findings), not silently regressed.
- **R8 (corrected) — FR-014 provenance**: an earlier pass believed a `work_item_projection`-view moduledoc
  correction had already landed on `development`'s copy of `local/store.ex`; that correction was real but
  belonged to the separate SQLite conversion of this module (commit `92e137e`), since split onto branch
  `local-tracker-sqlite` and no longer part of `development`. `development`'s own JSON-backed file never
  carried the stale language FR-014 concerns, so FR-014 still holds, independently confirmed rather than
  inherited from a mismatched provenance claim. No Constitution implication — this is a factual correction,
  not a scope or design change.
- **Persistence-neutral language**: every remaining reference in this feature's artifacts to Symphony's
  standalone local tracker as "SQLite-backed" has been corrected — `development`'s `Local.Store` is
  JSON-file-backed, and this feature's ownership-boundary claims (FR-014, User Story 4) never depended on
  its storage format to begin with. No Constitution implication.

No Constitution gate FAILs as a result of this correction pass.

## Project Structure

### Documentation (this feature)

```text
specs/002-bindle-integration/
├── plan.md                              # This file (/speckit-plan command output)
├── research.md                          # Phase 0 output (/speckit-plan command)
├── data-model.md                        # Phase 1 output (/speckit-plan command)
├── quickstart.md                        # Phase 1 output (/speckit-plan command)
├── contracts/
│   └── bindle-schedulable-projection.md # Phase 1 output — logical projection contract
└── checklists/
    └── requirements.md                  # Spec quality checklist (/speckit-specify output)
```

### Source Code (repository root)

This feature makes **zero** source changes. `development`'s current
`elixir/lib/symphony_elixir/local/store.ex` was verified during this feature's correction pass to already
satisfy FR-014 as-is (research.md R8) — no file in the repository is touched by this plan.

A future, separate implementation feature (out of scope here) would eventually make three kinds of change,
sketched in `data-model.md`/`contracts/bindle-schedulable-projection.md` for continuity, but **not created or
modified by this plan**:

```text
elixir/
└── lib/symphony_elixir/
    ├── tracker.ex              # NOT modified by this feature — sketch only: a future feature adds one new
    │                           #   OPTIONAL callback pair (acquisition/release, FR-015/data-model.md §3),
    │                           #   `@optional_callbacks`-guarded so every existing adapter is unaffected.
    ├── tracker/issue.ex        # NOT modified by this feature — sketch only: a future feature splits
    │                           #   `routable?/2`'s admission (`dispatchable`) and routing (labels) concerns
    │                           #   so continuation call sites can depend on routing without re-testing
    │                           #   admission (FR-017/data-model.md §2, research.md R11).
    ├── orchestrator.ex         # NOT modified by this feature — sketch only: a future feature wires calls to
    │                           #   the new optional callback pair at `do_dispatch_issue/4` (before
    │                           #   `Task.Supervisor.start_child`) and at `release_issue_claim/2`/
    │                           #   `terminate_running_issue/3`, plus new startup-time reconciliation logic
    │                           #   for the crash-recovery gap research.md R10 identifies as unresolved; and
    │                           #   corrects `reconcile_issue_state/4`/`reconcile_blocked_issue_state/4` to
    │                           #   stop re-testing `dispatchable` for an item already running/blocked
    │                           #   (FR-017), while resolving Linear's assignee-reassignment continuation
    │                           #   stop and Asana's completed-vs-section-name gap, each through a distinct
    │                           #   mechanism or an explicit, documented trade-off (research.md R11).
    ├── agent_runner.ex         # NOT modified by this feature — sketch only: a future feature corrects
    │                           #   `continue_with_issue?/2` the same way, for the same reason (FR-017).
    └── bindle/                 # NOT created by this feature — sketch only, for a future implementation
        ├── adapter.ex          # would implement @behaviour SymphonyElixir.Tracker (including the new
        │                       #   optional callbacks), mirroring local/adapter.ex, and open the published
        │                       #   SQLite artifact in SQLite's own read-only mode (spec FR-002)
        └── ...                 # supporting modules (naming, count, and shape decided at that feature's own planning stage)
```

**Structure Decision**: This feature is documentation/specification-only against the existing single-project
Elixir layout. No source tree is created or modified. A future Bindle-backed `Tracker` adapter would follow
the exact same per-adapter package convention every existing adapter (`local/`, `github/`, `gitlab/`,
`jira/`, `linear/`, `asana/`) already uses, registered the same way in `Tracker.@adapters`; the new
acquisition/release callback pair would be added to `tracker.ex` and wired into `orchestrator.ex` as one
narrow, adapter-agnostic addition, not a Bindle-specific branch — this plan establishes both shapes as the
expected implementation without creating either, since building them is not this feature's scope.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations. Table intentionally omitted.
