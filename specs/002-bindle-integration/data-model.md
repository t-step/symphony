# Data Model: Bindle-Backed Work Tracking

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

This feature introduces one new orchestrator-facing seam (§3, the acquisition/release callback pair,
research.md R10) beyond the read-side projection. It defines the **physical** shape of Bindle's published
projection artifact and confirms it maps 1:1 onto the existing `SymphonyElixir.Tracker.Issue` struct with no
new struct field. Nothing in this feature changes `Tracker.Issue` itself — see `SPEC.md` §4.1.1 and
`001-local-tracker-multi-agent`'s `data-model.md` §1 for the existing entity this feature reuses without
modification.

## 1. Bindle-Facing Schedulable Projection Record (physical shape fixed — research.md R1, R9)

Owned and published entirely by Bindle, as a physically separate, read-only SQLite database artifact
(research.md R1) — never a view living inside Bindle's own canonical database file. Research.md R1's
boundary-enforceability finding is why this must be a separate file: SQLite has no per-view access control,
so a view inside the same connection as Bindle's canonical tables would be an aspirational, not structural,
boundary. This table is the fixed **physical** column shape of that published artifact.

**Reworked against Bindle's actual implementation (research.md R9, 2026-08-27)**: Bindle's current,
unpublished, in-process `ProjectedWorkItem` (`src/bindle/work_ledger.py:457`) carries only `id`, `title`,
`terminal: bool`, `eligible: bool` — but that type is not the published artifact this specification requires
Bindle to build (research.md R1). The published artifact's shape below is purpose-built for this contract,
not constrained by `ProjectedWorkItem`'s current, never-published shape.

| Column | Maps to `Tracker.Issue` field | Notes |
|---|---|---|
| `id` | `id` | Stable identity of the top-level Bindle work unit, Bindle's own primary key. |
| `identifier` | `identifier` | Human-facing identifier, used for workspace-key derivation (`workspace_key/1`), same as every existing adapter. MAY reuse Bindle's own `id` verbatim — Bindle has no separate human-facing identifier column, and a stable `TEXT PRIMARY KEY` already satisfies `workspace_key/1`'s stability requirement. |
| `title` | `title` | Required non-blank for `candidate_issue?`, same as every existing adapter. |
| `description` | `description` | Same as every existing adapter; Bindle's `work_items.description` maps straight across. |
| `status` | `state` | **Direct passthrough, no synthesis** (research.md R9, superseding the prior `(terminal, eligible)`-synthesis requirement). Bindle's own native status string for `type = 'task'` rows (`open`/`done`/`superseded`) maps straight onto `Tracker.Issue.state`. A Bindle-backed `WORKFLOW.md` configures `active_states`/`terminal_states` to name these values directly (e.g. `active_states: ["open"], terminal_states: ["done", "superseded"]`), exactly as any other adapter's operator configures state names today. |
| `dispatchable` | `dispatchable` | REQUIRED, precomputed entirely by Bindle from its richer internal state (dependencies, claims, execution state, evidence, reconciliation state) — the same computation Bindle already performs for its internal `eligible` fact (`status = 'open' AND` not claimed `AND` not blocked), published here as a named column. Symphony consumes this verbatim — it MUST NOT be derived, cross-checked, or recomputed on the Symphony side (spec FR-003). A point-in-time snapshot as of the projection's last publish, MAY be stale by dispatch time — see §3 below (research.md R10) for why real-time arbitration still happens separately. |
| `created_at` | `created_at` | **Added beyond the original logical table** (research.md R9): `sort_issues_for_dispatch/1` (orchestrator.ex) ranks dispatch candidates by `(priority_rank, created_at_sort_key, identifier)` — omitting `created_at` would collapse every simultaneously-eligible Bindle issue to alphabetical-by-`identifier` dispatch order, discarding real submission-order signal. Bindle's `work_items.created_at` already exists, so including it costs nothing on Bindle's side. |

**Deliberately NOT columns in this artifact** (left at `Tracker.Issue`'s existing struct default —
verified by direct code audit that none of them gate any dispatch/candidacy/reconciliation decision outside
adapter-internal code or an operator's own optional prompt-template reference):

- `native_ref` — consumed only inside adapters' own agent-tool code; a Bindle adapter can set this to `id` internally without Bindle needing to project a separate value.
- `priority` — Bindle's `work_items` has no priority column; inventing one is not warranted. Bindle-sourced issues fall back to the existing default priority rank, ordered secondarily by `created_at` then `identifier`.
- `branch_name`, `url`, `assignee_id`, `labels`, `blocked_by`, `updated_at` — no gating read exists anywhere outside adapter code or optional prompt-template rendering; Bindle's data model has no equivalent for most of them.

**What is deliberately absent from this table, by design (spec FR-004, FR-011)**: any claim identity,
evidence record, milestone reference, raw dependency-graph edge, reconciliation-state field, or other
Bindle-internal concept. If a future concrete design finds it needs to add a column beyond this table to
satisfy a demonstrated Symphony-side requirement, that is itself a signal requiring a spec amendment to this
feature (a new FR), not a silent schema addition during implementation.

**Schema integrity (research.md R1)**: The published artifact MUST carry a schema-version marker (e.g. a
`schema_version` row or SQLite `user_version` pragma) that Symphony's adapter validates at open time, failing
loud on a mismatch rather than silently misreading a renamed or reordered column. Symphony's adapter MUST
always query by column name, never positionally. This also protects against a misconfigured
`tracker.provider.path` accidentally pointing at Bindle's canonical file instead of the published artifact —
the local tracker's own path validation today only checks "non-empty string," which a Bindle adapter must not
naively inherit unchanged.

## 2. Projection Membership vs. Admission (two independent axes — research.md R5)

Restated here as a data-model-level invariant, since it governs how every record in §1 is produced:

- **Membership** (is this record present in the projection at all): Bindle-owned. A record for a Bindle
  work item exists in the projection **only if** that item is a top-level, independently schedulable
  implementation unit. Items that are nested under a larger slice, evidence-only, reconciliation-only, or
  otherwise not independently schedulable **never** produce a projection record, regardless of any other
  state. Grounded directly: Bindle's actual `WorkLedger.generate_projection()` implements this as a hard
  `WHERE wi.archived_at IS NULL AND wi.type = 'task'` predicate (`src/bindle/work_ledger.py:1326`) — a
  `type = 'milestone'` row (Bindle's nested/grouping/human-acceptance unit) can never reach the query result,
  "not a filter a caller could bypass by reading the table directly" in Bindle's own words (research.md R5).
- **Admission** (`dispatchable`, for records that are present): Bindle-owned, independent of membership.
  A member record MAY have `dispatchable: false` — for example, a top-level unit that is currently blocked
  by an unresolved dependency remains a legitimate, independently schedulable unit conceptually, so it MAY
  still appear in the projection with `dispatchable: false`, rather than being removed from the projection
  outright. Both representations (omit entirely, or include as non-dispatchable) satisfy spec FR-002; the
  eventual implementation feature confirms which one Bindle actually produces.

Symphony's read side requires no change to support either representation: `Tracker.Issue.routable?/2` already
gates on `dispatchable` first (`tracker/issue.ex`), so a non-dispatchable member record is already correctly
excluded from scheduling today, with no Bindle-specific logic required.

## 3. Tracker Acquisition/Release Seam (new — spec FR-015/FR-016, research.md R10)

Bindle's canonical model has real, durable, atomically-arbitrated claims —
`work_item_claims(work_item_id PK, owner, claimed_at, worktree_path, branch)`, arbitrated by the table's own
primary-key constraint. Bindle's own contract is explicit that a coordinator MUST call `claim()` before
treating an item as acquired — the projection's `dispatchable` fact (§1) is advisory/snapshot only, never a
substitute. Symphony's orchestrator today tracks claims *only* in an in-memory `MapSet`, with a real race
window between reading candidates and actually dispatching.

This specification therefore requires (spec FR-015) a new, narrow, OPTIONAL pair of `SymphonyElixir.Tracker`
behaviour callbacks:

- **Acquisition callback**: called by the orchestrator immediately before treating a candidate issue as
  dispatched, when the active adapter implements it. A result other than success means the orchestrator skips
  dispatching that issue in the current cycle — the same shape as failing `candidate_issue?` today.
- **Release callback**: called by the orchestrator at every point it already releases its own in-memory claim
  today — retry-exhausted, terminal-state transition, routed-away, or missing-issue detection — but *not*
  merely because a retry is being scheduled, since the same workspace/branch is intentionally reused across
  retry backoff.

Both callbacks are optional via `@optional_callbacks`/`function_exported?/3`, mirroring the existing
optional-callback pattern already used for `agent_tool_specs/0`/`validate_config/1` — every adapter existing
as of this specification (local, GitHub, GitLab, Jira, Linear, Asana) is a complete, unconditional no-op.

**Deliberately unresolved by this specification, for the eventual implementation feature's own planning
stage** (spec FR-015; not hand-waved as already solved):

1. **Call-site timing**: Bindle's `claim()` wants `worktree_path`/`branch`, which today only exist *after*
   `Task.Supervisor.start_child` already spawned the Task (inside `AgentRunner`) — after the naive
   "acquire immediately before spawn" call site. `Workspace.workspace_key/1` is a pure function of
   `identifier` alone, so the path is computable earlier if dispatch order changes, but this specification
   does not itself reorder dispatch.
2. **Crash recovery**: Bindle's claims carry no TTL/lease. A Symphony process crash between a successful
   acquisition and the corresponding work being fully underway strands the claim with no automatic release.
   Resolving this needs new startup-time reconciliation logic (query Bindle for this instance's own owner-id
   claims with no matching in-memory running entry, and release them) — genuine new orchestrator-side work.
3. **Owner identity**: a stable per-Symphony-instance "owner" value for these calls does not exist anywhere
   in Symphony today (verified: no `node()`/instance-id/hostname-based identity concept anywhere in the
   codebase) and must be invented (e.g. a generated/config UUID per deployment), not assumed reusable.

This seam is adapter-agnostic in its public shape — no Bindle vocabulary (claim, worktree, branch, owner)
appears in the `Tracker` behaviour's callback names or required semantics; only a Bindle-backed adapter's own
implementation of the callbacks is free to be Bindle-specific internally (spec FR-004).

## 4. Bindle-Backed Tracker Adapter (future, out of scope for this feature's implementation — research.md R3)

Not built by this feature. Sketched here only so the data model above has a concrete consumer to reference:
a future `SymphonyElixir.Tracker`-behaviour-implementing module, structurally identical in shape to
`SymphonyElixir.Local.Adapter` (the same six existing callbacks: `fetch_issues_by_states/1`,
`fetch_issues_by_ids/1`, `agent_tool_specs/0`, `execute_agent_tool/3`, `secret_environment_names/1`,
`validate_config/1`, plus the new optional acquisition/release pair from §3), reading only the projection in
§1, performing real-time acquisition per §3, and writing lifecycle mutations only through a Bindle-owned
write path (research.md R2) scoped to the current session's bound item (spec FR-009/FR-010) — never a
second, richer read/write surface.

## 5. Symphony Standalone Local Tracker (existing, unmodified — `001-local-tracker-multi-agent`)

No change to `Local.Store`'s schema, queries, or behavior. The FR-014 moduledoc correction removing language
that described its `work_item_projection` view as a future Bindle-model growth boundary is **already landed**
in the current codebase (verified directly against `elixir/lib/symphony_elixir/local/store.ex` during this
feature's rework) — no further change to that module is required by this feature. `work_items`,
`work_item_projection`, and every existing field remain exactly as `001-local-tracker-multi-agent` already
specifies and implements them. The separate JSON-to-SQLite conversion of this module (a distinct, already-
landed commit on this same git branch) has zero coupling to this feature — see `plan.md`'s Project Structure
for the recommended repository-hygiene separation of that commit from this branch.
