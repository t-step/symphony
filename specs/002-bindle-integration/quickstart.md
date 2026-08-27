# Quickstart: Validating the Bindle Integration Boundary

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md) | Contract: [contracts/bindle-schedulable-projection.md](./contracts/bindle-schedulable-projection.md)

This feature ships a specification, a plan, and one documentation correction — not a runtime capability.
Its validation therefore splits into two parts: what can be checked **now**, by inspection, and what a
**future** implementation feature must demonstrate once a concrete Bindle-backed adapter exists.

## Part 1 — Validate now (this feature's actual deliverable)

### Scenario A: The existing `Tracker` contract needs no change (User Story 1, SC-001)

1. Open `elixir/lib/symphony_elixir/tracker.ex` and confirm its six callbacks
   (`fetch_issues_by_states/1`, `fetch_issues_by_ids/1`, `agent_tool_specs/0`, `execute_agent_tool/3`,
   `secret_environment_names/1`, `validate_config/1`) and `elixir/lib/symphony_elixir/tracker/issue.ex`'s
   struct fields.
2. Confirm every field in `data-model.md` §1's Bindle-Facing Schedulable Projection Record table maps to an
   existing `Tracker.Issue` field with no new field required.
3. **Expected outcome**: no diff is needed to `tracker.ex` or `tracker/issue.ex` to support the design this
   spec describes.

### Scenario B: The `Local.Store` moduledoc no longer implies a shared future store (FR-014, SC-003)

1. Open `elixir/lib/symphony_elixir/local/store.ex` and read its moduledoc.
2. **Expected outcome**: it states that `Local.Store` is Symphony's own standalone, independent local
   work-tracking implementation, and that a future Bindle-backed tracker is a separate `Tracker` adapter —
   not that `work_item_projection` (or any other part of this module) is "the boundary" a future
   Bindle model grows into or shares.
3. Run the existing local-tracker test suites to confirm the correction changed no behavior:
   ```bash
   cd elixir && mix test test/symphony_elixir/local_store_test.exs test/symphony_elixir/local_adapter_test.exs test/symphony_elixir/local_init_test.exs
   ```
   **Expected outcome**: all tests pass, identically to before this feature's documentation correction.

### Scenario C: Membership vs. admission needs no new Symphony-side logic (User Story 3, SC-002)

1. Open `elixir/lib/symphony_elixir/tracker/issue.ex` and confirm `routable?/2` already gates on
   `dispatchable` before consulting labels, and that `blocked_by` is carried as informational data rather
   than used to compute dispatch eligibility inside Symphony.
2. **Expected outcome**: a hypothetical Bindle-backed adapter record with `dispatchable: false` is already
   excluded from scheduling by existing, unmodified code — no Bindle-specific branch is needed anywhere in
   `orchestrator.ex` or `tracker.ex`.

### Scenario D: The acquisition/release seam is narrow and its call sites are identifiable (User Story 2, FR-015)

1. Open `elixir/lib/symphony_elixir/orchestrator.ex` and locate `do_dispatch_issue/4` (the point immediately
   before `spawn_issue_on_worker_host/5`/`Task.Supervisor.start_child`), `release_issue_claim/2`, and
   `terminate_running_issue/3`.
2. Confirm these are exactly the call sites data-model.md §3 names for the new optional acquisition/release
   callback pair, and that today's in-memory `state.claimed` `MapSet` bookkeeping at those same sites is
   what the new callbacks run alongside, not replace.
3. **Expected outcome**: no other location in the orchestrator needs to change to satisfy FR-015 — the seam
   is exactly two call sites, both already load-bearing for today's in-memory claim bookkeeping.

## Part 2 — Validate once a Bindle-backed adapter is actually implemented (future feature, out of scope here)

These scenarios cannot be run today because no concrete Bindle-backed adapter exists in or alongside this
repository yet. They are recorded here so the eventual implementation feature inherits ready-made acceptance
scenarios instead of re-deriving them, mirroring how `001-local-tracker-multi-agent`'s own quickstart
scenarios anchor its acceptance criteria.

**Grounding note (reworked 2026-08-27)**: Bindle's own `WorkLedger.generate_projection()`
(`~/Developer/bindle/src/bindle/work_ledger.py:1326`) is a real, tested method today, but it is Bindle's
current *in-process* return value, not the published artifact this specification requires (FR-002) — Bindle
has not yet built the physically separate, schema-versioned SQLite artifact this contract fixes (research.md
R1), nor the `claim()`/`release_claim()` write surface a Symphony-side acquisition seam would call into. The
eventual implementation feature's test double for Scenarios 1–2 below can still be built against Bindle's
actual `WorkLedger`/schema knowledge (`work_items`, `work_item_claims`, `tests/test_work_ledger.py` in that
repository), materialized into a small on-disk SQLite fixture matching data-model.md §1's column shape,
rather than an invented shape — but building the projection artifact and the write surface for real is
Bindle-side work this specification requires without itself performing.

1. **End-to-end dispatch through a Bindle-backed tracker**: configure a deployment with the future
   `tracker.kind` value (research.md R4) pointing at a projection artifact (real, once Bindle builds it per
   FR-002, or a test-double SQLite file matching data-model.md §1's exact column shape) containing one
   `type = 'task'`, dispatchable work item; confirm Symphony polls, calls the acquisition callback (FR-015),
   dispatches, executes, and completes it exactly as it would for any other tracker (spec User Story 1,
   Acceptance Scenario 2).
2. **Ineligible items never dispatch, and dispatch-time arbitration is real**: seed the same fixture with a
   blocked task, a `type = 'milestone'` item, and a task already claimed by another owner; confirm the
   milestone never appears in the projection at all (Bindle's own `WHERE type = 'task'` predicate, not
   something the adapter needs to filter), the blocked/claimed tasks appear with `dispatchable: false`
   rather than being dispatched (spec User Story 3, Acceptance Scenarios 1–3), and separately confirm that
   even a `dispatchable: true` record fails to dispatch if the acquisition callback's underlying `claim()`
   call loses the race to a concurrent claimant (spec User Story 2, Acceptance Scenarios 1–2).
3. **Single-active-source enforcement**: confirm a deployment cannot simultaneously configure the standalone
   local tracker and a Bindle-backed tracker, and that switching between them requires an explicit restart-
   time configuration change with no automatic data carryover (spec User Story 4, Acceptance Scenario 2;
   Edge Cases).
4. **Mechanical-evidence boundary holds under implementation**: confirm no part of the actual Bindle-backed
   adapter implementation duplicates any mechanical evidence check (file-change detection, test/check
   pass/fail, commit existence, artifact production, dependency/state-transition consistency) — these
   remain entirely Bindle-side, verified by code review against spec FR-012 rather than a runtime test.
5. **Transient vs. established-loss failure handling**: simulate a temporary projection-read failure during
   a poll tick and confirm Symphony's existing tracker/source failure handling applies (skip and retry,
   running attempts undisturbed — spec FR-008); simulate a schema-version-marker mismatch on the projection
   artifact and confirm the same fail-loud handling applies (contract's Transport obligations); separately
   confirm whatever establishment/loss distinction the chosen transport actually supports (research.md R7)
   behaves as that implementation feature's own plan documents — honestly, including if full FR-013 parity
   was not achievable.
6. **Crash-recovery reconciliation is a named gap, not assumed solved**: confirm that a Symphony instance
   restarting after a crash mid-acquisition either (a) implements the startup-time reconciliation logic
   research.md R10 identifies as required (querying Bindle for this instance's own stranded claims and
   releasing them), or (b) the implementation feature's plan explicitly documents this as a known,
   unresolved limitation rather than silently omitting it.
