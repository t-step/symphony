# Feature Specification: Bindle-Backed Work Tracking Through a Narrow Schedulable Projection

**Feature Branch**: `002-bindle-integration` (Spec Kit feature identifier only; per the fork's workflow — see `001-local-tracker-multi-agent` — no separate git branch is created for this feature; work stays on `development`)

**Created**: 2026-08-27

**Status**: Draft

**Input**: User description: "Rework the current Symphony/Bindle integration design around the architecture we have now settled on. Bindle owns durable implementation state (slices, dependencies/blocking, claims, execution state, evidence, reconciliation state, other coordination metadata). Symphony must not own or reconstruct that model. Bindle exposes a deliberately narrow schedulable projection; Symphony consumes that projection through its existing tracker abstraction and produces its existing Tracker.Issue shape, unchanged. Symphony's scheduler/orchestrator must not need to understand Bindle's richer state. Symphony should primarily see top-level schedulable implementation units; blocked/nested/evidence-only/reconciliation-only items stay in Bindle and must not become assignable Symphony work. `dispatchable` (or equivalent) is an upstream fact from the projection, never recomputed by Symphony. Bindle mechanically verifies objective evidence; humans resolve semantic completion/correctness — this must not become a general-purpose workflow engine. The current SQLite-backed `Local.Store`/`Local.Adapter` (feature 001) is Symphony's own standalone local tracker, not the future canonical Bindle store, and must not be documented as the growth path for a richer Bindle model. Prefer the smallest architectural change; avoid shared mutable database ownership, JSON sync layers, Git-backed coordination state, hosted control planes, or unneeded new infrastructure."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build the Bindle-backed tracker as an ordinary Tracker adapter, not a scheduler change (Priority: P1)

An engineer implementing Symphony's future Bindle-backed tracker needs an unambiguous, narrow contract to build against: what Bindle must expose, what shape Symphony consumes, and — critically — confirmation that no orchestrator, dispatcher, agent-runner, or workflow-store code needs to change to support it. Without this, the natural failure mode is scope creep: richer Bindle concepts (claims, evidence, milestones, dependency graphs) leaking into Symphony's scheduling core because no boundary was specified in advance.

**Why this priority**: This is the foundational architectural decision the whole feature exists to fix. Every other requirement in this spec depends on establishing that the seam is "another Tracker adapter," not a new subsystem.

**Independent Test**: Confirm, by inspection of `SymphonyElixir.Tracker`'s existing behaviour (`fetch_issues_by_states/1`, `fetch_issues_by_ids/1`, `agent_tool_specs/0`, `execute_agent_tool/3`, `secret_environment_names/1`, `validate_config/1`) and `SymphonyElixir.Tracker.Issue`'s existing struct shape, that a Bindle-backed adapter can be described entirely in terms of those callbacks and that struct, with zero new orchestrator-facing callback, field, or entity required.

**Acceptance Scenarios**:

1. **Given** this specification and Symphony's existing `Tracker` behaviour, **When** a future implementer designs the Bindle-backed adapter, **Then** they can express every requirement below using only the six existing `Tracker` callbacks and the existing `Tracker.Issue` fields — no new orchestrator-facing behaviour, callback, or struct field is required.
2. **Given** a running Symphony deployment configured against a Bindle-backed tracker, **When** the orchestrator polls, dispatches, retries, or reconciles work, **Then** it applies exactly the same scheduling logic (dispatch order, concurrency limits, retry/backoff, reconciliation) it applies to any other tracker, with no Bindle-specific branch anywhere in orchestrator/dispatcher/agent-runner/workflow-store code.

---

### User Story 2 - See only independently schedulable work, never Bindle's internal bookkeeping (Priority: P1)

An operator running Symphony against Bindle-managed work wants Symphony's dispatch queue to contain only implementation units that are actually ready to hand to a coding agent right now — not every row in Bindle's ledger. Blocked work, sub-items of a larger slice, evidence records, and reconciliation-only bookkeeping entries are real and useful inside Bindle, but none of them are things a coding-agent session should ever be dispatched to work on directly.

**Why this priority**: This is the concrete mechanism that keeps Symphony's scheduler ignorant of Bindle's richer model. Get this wrong and Symphony either dispatches work it shouldn't (nested/blocked items) or under-dispatches because eligibility logic was reimplemented incorrectly on the Symphony side.

**Independent Test**: Given a Bindle ledger containing a mix of top-level schedulable units, blocked units, nested sub-items, evidence-only records, and reconciliation-only records, confirm that only the top-level schedulable units appear in the Bindle-facing projection Symphony reads, and that each one carries a pre-computed admission fact (equivalent to today's `dispatchable`) that Symphony consumes verbatim rather than deriving from blocking/nesting/evidence state.

**Acceptance Scenarios**:

1. **Given** a Bindle work item that is blocked by an unresolved dependency, **When** Symphony's tracker adapter reads the projection, **Then** that item either does not appear in the projection at all, or appears with its admission fact set to not-dispatchable — in neither case does Symphony consult Bindle's dependency/blocking data directly to make that determination itself.
2. **Given** a Bindle work item that is nested under a larger slice, evidence-only, or reconciliation-only, **When** Symphony's tracker adapter reads the projection, **Then** that item never appears in the projection, regardless of any other state it holds in Bindle.
3. **Given** a top-level Bindle work item that becomes blocked between two polls, **When** Symphony polls again, **Then** the projection reflects the new admission state (item removed, or its admission fact flips) without Symphony having recomputed eligibility from richer Bindle state.

---

### User Story 3 - Choose standalone local tracking or Bindle-backed tracking without ambiguity (Priority: P2)

An operator configuring a Symphony deployment wants to pick exactly one work-tracking source — Symphony's own standalone local (SQLite) tracker, a Bindle-backed tracker, or a hosted tracker — and have no doubt about which one is active, with no shared state or silent substitution between the standalone local tracker and a Bindle-backed tracker.

**Why this priority**: Directly prevents the specific confusion this feature exists to correct: conflating Symphony's own local SQLite store with a future Bindle-backed store merely because both happen to use SQLite.

**Independent Test**: Confirm that Symphony's tracker-selection configuration treats "standalone local tracker" and "Bindle-backed tracker" as two distinct, mutually exclusive choices within the existing single-active-work-tracking-source model, and that no code path or documentation implies one is a subset, precursor, or storage layer of the other.

**Acceptance Scenarios**:

1. **Given** a deployment configured to use Symphony's standalone local tracker, **When** an operator or future maintainer reads its documentation or source, **Then** nothing states or implies that its database, schema, or module is the location a future Bindle-backed tracker's data will live in or grow into.
2. **Given** a deployment, **When** it selects a work-tracking source, **Then** exactly one of {a hosted tracker, the standalone local tracker, a Bindle-backed tracker} is active, consistent with the existing single-active-source model (`001-local-tracker-multi-agent` FR-012) — a Bindle-backed tracker is one more alternative for that same single slot, not a second concurrently active source.

---

### User Story 4 - Keep mechanical evidence inside Bindle and semantic judgment with humans (Priority: P3)

A team wants Bindle to catch objective, mechanically-checkable gaps (a required file never changed, a check never ran, no commit exists, an expected artifact is missing, a dependency/state transition is internally inconsistent) without Symphony reimplementing any of that logic, while trusting that whether the *work itself* is actually correct or complete remains a human call, not something either system infers automatically.

**Why this priority**: Lower priority than the architectural boundary itself, but explicitly called out because the natural next mistake — once mechanical verification exists — is to keep expanding it until it quietly becomes a semantic-completion or general workflow engine.

**Independent Test**: Confirm this specification names concrete categories of mechanical evidence Bindle may check, states plainly that Symphony performs none of that checking itself, and states plainly that semantic completion/correctness judgment is not automated by either system.

**Acceptance Scenarios**:

1. **Given** a Bindle-managed work item whose mechanical evidence checks (file changes, expected tests/checks, commit existence, artifact production, dependency/state consistency) have not been satisfied, **When** Bindle evaluates it, **Then** Bindle — not Symphony — is the system that determines it is not yet ready, and Symphony's only visibility into that fact is through the item's ordinary state/admission fields in the projection.
2. **Given** a Bindle-managed work item whose mechanical evidence checks all pass, **When** a human has not yet confirmed the work is semantically correct/complete, **Then** neither Bindle nor Symphony automatically marks the item as done on the human's behalf.

---

### Edge Cases

- What happens when the Bindle-facing projection is temporarily unreachable during a poll or reconciliation pass? Symphony MUST treat this the same way it already tolerates any other tracker/source outage — skip the affected poll tick or reconciliation pass, retry on the next one, and leave already-running work-item attempts undisturbed (mirrors `001-local-tracker-multi-agent` FR-008.3) — not as an individual work-item attempt failure.
- What happens when a Bindle-backed tracker that has previously been operating becomes permanently misconfigured or unreachable (as opposed to a transient outage)? Symphony MUST surface this as an operator-visible failure of the work-tracking source itself, to the extent the Bindle-facing projection interface can supply that distinction — see FR-007 for the honest limits of what this spec can guarantee here without a concrete projection interface already in hand.
- What happens if an operator has both a previously-established standalone local tracker database and a Bindle-backed tracker configured for the same deployment over time? The two are entirely independent stores with no automatic migration, synchronization, or data sharing between them; switching a deployment's `tracker.kind` selection is an explicit operator action with no implied carryover of state from one to the other.
- What happens when a Bindle work item's admission fact and its blocking/dependency state seem to disagree (for example, a projection bug marks something dispatchable while it is still blocked upstream in Bindle)? This is a Bindle-side projection defect; Symphony has no independent way to detect or correct it, since Symphony is specified to trust the projection's admission fact as an upstream fact by design (FR-003) rather than cross-checking it against blocking state it is not given.
- What happens to an in-flight coding-agent run for a Bindle-managed item if that item is later marked blocked, nested, or otherwise made ineligible inside Bindle? Symphony's existing behavior for an item that leaves the tracker's visible active set while a run is in flight applies unchanged — this specification introduces no new mid-run cancellation or interruption behavior beyond what the existing tracker contract already defines.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST be able to consume Bindle-managed work exclusively through its existing `SymphonyElixir.Tracker` adapter boundary and produce the existing `SymphonyElixir.Tracker.Issue` struct, unchanged in shape, exactly as every other adapter (GitHub, GitLab, Jira, Linear, Asana, the standalone local tracker) already does.
- **FR-002**: The Bindle-facing projection Symphony reads MUST expose only top-level, independently schedulable implementation units. Items that are blocked, nested under another unit, evidence-only, reconciliation-only, or otherwise not independently schedulable MUST NOT appear to Symphony as assignable work — either by being absent from the projection or by carrying a non-dispatchable admission fact, per FR-003.
- **FR-003**: Dispatch admission (the equivalent of today's `dispatchable`) for a Bindle-managed item MUST be supplied by the projection as a precomputed, upstream fact. Symphony MUST NOT derive, infer, or recompute dispatch eligibility from Bindle's richer state (dependency graphs, claims, evidence, reconciliation state) itself.
- **FR-004**: Symphony's orchestrator, dispatcher, agent runner, and workflow store MUST NOT require any knowledge of Bindle's internal model — claims, evidence, reconciliation state, milestones, or dependency-graph internals — beyond what already exists on `Tracker.Issue` (state, labels, priority, `blocked_by` refs, `dispatchable`, and the other existing fields).
- **FR-005**: A Symphony deployment MUST have at most one active work-tracking source at a time. A Bindle-backed tracker is one additional alternative within that existing single-active-source slot (`001-local-tracker-multi-agent` FR-012) — alongside a hosted tracker and Symphony's standalone local tracker — never a second, simultaneously active source.
- **FR-006**: Selecting a Bindle-backed tracker MUST be a distinct, explicit configuration choice from selecting Symphony's own standalone local tracker. An operator MUST NOT be able to configure one and unknowingly get the other, and neither selection MUST silently substitute for the other.
- **FR-007**: Symphony SHOULD distinguish, for a Bindle-backed tracker, between "not yet reachable/configured" and "previously operating, now failing," the same way `001-local-tracker-multi-agent` FR-013 requires for the standalone local tracker — to the extent the eventual Bindle-facing projection interface can supply that distinction. This specification does not assume a concrete projection interface already exists to guarantee it; the eventual implementation's planning stage MUST confirm what distinction the chosen interface can actually provide and MUST surface any gap explicitly rather than silently assume it is solved.
- **FR-008**: A transient failure to read the Bindle-facing projection during polling or reconciliation MUST be handled by Symphony's existing tracker/source failure handling — skip the affected poll tick or reconciliation pass, retry on the next one, leave already-running work-item attempts undisturbed — MUST NOT be treated as an individual work-item attempt failure.
- **FR-009**: Lifecycle-state mutations a coding-agent session performs against a Bindle-managed work item MUST flow through Symphony's existing agent-invoked, host-executed tracker-write boundary (`agent_tool_specs/0` + `execute_agent_tool/3`) — this feature MUST NOT add a new orchestrator-owned tracker-write API.
- **FR-010**: Any tracker-write tool Symphony exposes against a Bindle-managed item MUST be scoped to the work item bound to the current coding-agent session, mirroring the existing standalone local tracker's `local_tracker_set_state` scope restriction — it MUST NOT be able to target an arbitrary Bindle work item.
- **FR-011**: This specification MUST NOT define, invent, or require any Bindle-internal capability beyond what is needed to define the Symphony-facing projection's contract (its membership rules, admission semantics, and failure surface). Bindle's own internal ledger schema, dependency/claims/evidence/reconciliation engine, and durable-storage mechanism remain entirely out of scope for Symphony's specification and implementation.
- **FR-012**: Bindle's mechanical evidence verification (whether required files changed, whether expected tests/checks ran and passed, whether commits exist, whether artifacts were produced, whether dependency/state transitions are internally consistent) MUST remain entirely inside Bindle. Symphony MUST NOT reimplement, duplicate, or partially reimplement any of this verification.
- **FR-013**: Semantic completion or correctness judgment for Bindle-managed work MUST remain human-resolved (within Bindle or upstream of it). Neither this specification nor any future implementation of it MUST introduce automated semantic-completion inference as a substitute for that human judgment.
- **FR-014**: Symphony's own standalone local tracker (`SymphonyElixir.Local.Store`/`SymphonyElixir.Local.Adapter`, SQLite-backed, `001-local-tracker-multi-agent`) and its documentation MUST NOT describe or imply that its storage, schema, or module is the location a future Bindle model will grow into, is shared with a future Bindle-backed tracker, or is otherwise the same system as one. Existing documentation/comments found to say otherwise MUST be corrected as part of this feature's supporting analysis (see Assumptions).

### Key Entities

- **Bindle-Facing Schedulable Projection**: The narrow, read-oriented interface Bindle exposes to Symphony. Each record in it corresponds 1:1 to a top-level, independently schedulable Bindle implementation unit and maps onto `Tracker.Issue.t()` with no lossy or extended transform — it carries no claims, evidence, milestone, or dependency-graph detail, only the same class of fields every existing adapter already supplies. Its concrete transport (a read-only database view, a query API, or another mechanism) is an implementation decision for the eventual Bindle-backed-tracker feature's planning stage, not fixed by this specification.
- **Bindle-Backed Tracker (Symphony-side)**: A future `SymphonyElixir.Tracker` adapter, structurally analogous to the existing `local`/`github`/`gitlab`/`jira`/`linear`/`asana` adapters, that reads only the Bindle-Facing Schedulable Projection and writes only narrowly-scoped lifecycle mutations back through it. It owns no Bindle state of its own and reconstructs none of Bindle's richer model.
- **Symphony Standalone Local Tracker** (existing, unchanged by this feature — see `001-local-tracker-multi-agent`): Symphony's own independent, SQLite-backed local work-tracking implementation. Explicitly a different system from a future Bindle-backed tracker, sharing no storage, schema, or growth path with it, despite both currently happening to use SQLite.
- **Bindle Durable Implementation Ledger** (owned entirely by Bindle, out of scope for Symphony's own specification/implementation): Slices/top-level work units, dependencies/blocking, claims, execution state, evidence, reconciliation state, and other coordination metadata. Referenced here only to establish the ownership boundary; its internal shape is not specified by this document.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A future implementer can build the Bindle-backed tracker as a single new `Tracker` adapter module, following the existing `local`/`github`/`gitlab`/`jira`/`linear`/`asana` package shape, with zero required changes to orchestrator, dispatcher, agent-runner, or workflow-store code beyond registering the new adapter — the same class of change `001-local-tracker-multi-agent` already made to add the standalone local tracker.
- **SC-002**: In every scenario documented in this specification, no Bindle work item that is blocked, nested, evidence-only, or reconciliation-only appears to Symphony as schedulable or dispatchable work.
- **SC-003**: After this feature's documentation correction (FR-014) lands, no source comment, moduledoc, or README section in this repository describes Symphony's standalone local tracker as the future home of a richer, externally-owned (Bindle) work model.
- **SC-004**: An operator can determine, from a deployment's own configuration, which one of {hosted tracker, standalone local tracker, Bindle-backed tracker} is active, with no configuration state shared between the standalone local tracker and a Bindle-backed tracker.
- **SC-005**: A team can run one Symphony deployment against Bindle-managed work and a separate deployment against a hosted tracker or the standalone local tracker without either deployment's tracker choice or data affecting the other, preserving the existing single-active-work-tracking-source invariant.

## Out of Scope / Non-Goals

- Designing or specifying Bindle's own internal schema, storage engine, dependency/claims/evidence model, or reconciliation logic — that belongs to Bindle's own project, not this repository's specification.
- Implementing the Bindle-backed `Tracker` adapter itself, or any concrete projection transport (SQL view, query API, or otherwise) — this specification defines the contract the eventual implementation feature must satisfy; it is not that implementation.
- A second orchestration engine, workflow engine, or generic task-lifecycle framework inside Bindle or Symphony.
- Teaching Symphony to understand claims, evidence, reconciliation state, milestones, or dependency-graph internals for any purpose beyond consuming the narrow projection this specification defines.
- Automated resolution of semantic completion or correctness — this remains human-resolved by design, not a gap to be closed by future automation.
- Any migration or synchronization mechanism between Symphony's standalone local tracker and a future Bindle-backed tracker; the two are independent, non-interacting stores.
- Shared mutable database ownership between Symphony and Bindle, a JSON synchronization layer, Git-backed coordination state, a hosted control plane, or any other new infrastructure dependency not demonstrably required by the requirements above.
- Rewriting or reopening `001-local-tracker-multi-agent`'s frozen specification, plan, or tasks; this feature supersedes only the specific stale framing identified in FR-014, via a narrow, explicitly-scoped documentation correction, not a rewrite of that feature's history.

## Assumptions

- Bindle is a separate system, developed and evolved outside this repository; this specification defines only the Symphony-facing seam it must expose, not Bindle's own architecture.
- The existing `SymphonyElixir.Tracker` behaviour and `Tracker.Issue` struct (confirmed against `SPEC.md` §11 and the current adapter implementations) are already sufficient to represent a Bindle-managed top-level work item without any new field or callback — this was confirmed during specification, not assumed without verification.
- A future Bindle-backed adapter is added to Symphony's existing `Tracker.@adapters` map the same way `local` was added in `001-local-tracker-multi-agent`; no new orchestrator-facing behaviour is introduced by that registration.
- The concrete `tracker.kind` value and configuration field names for a Bindle-backed tracker are left unspecified here and belong to the eventual implementation feature's planning stage, consistent with how `001-local-tracker-multi-agent` deferred its own lifecycle-write mechanism (its FR-003/FR-011) to planning.
- Whether the projection is realized as a direct read-only SQLite view, a query API, or another mechanism is likewise a planning-stage decision for the eventual implementation feature, guided by this specification's requirements (FR-001–FR-004) but not fixed by it.
- Correcting the specific stale moduledoc language identified in FR-014 (`elixir/lib/symphony_elixir/local/store.ex`, which currently frames its `work_item_projection` view as "the named boundary a future richer, externally-owned work model... would sit behind") is an in-scope documentation correction for this feature — a comment-only change describing existing, unmodified behavior, not new implementation.
- This specification was re-checked directly against Bindle's actual implementation (`~/Developer/bindle`, `specs/001-durable-work-ledger/`, `specs/002-milestone-task-work-items/`, `src/bindle/work_ledger.py`, `docs/SYMPHONY.md`, `docs/DECISIONS.md` D037/D038) on 2026-08-27, after this spec was first written. No functional requirement changed as a result — the architecture here converges with what Bindle independently built (task/milestone membership filtering, a precomputed admission boolean, no dependency/DAG logic leaking to a coordinator, mechanical-evidence-vs-human-acceptance separation). Where the grounding pass sharpened a previously deferred mechanism-level assumption (projection transport leaning, and the concrete field shape a future adapter must handle), see `research.md` R1 and R9 and their downstream edits to `data-model.md` and `contracts/bindle-schedulable-projection.md`.
