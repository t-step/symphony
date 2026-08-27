# Data Model: Bindle-Backed Work Tracking

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

This feature introduces no new orchestrator-facing entity. It defines the **logical** shape of a future
Bindle-facing projection record and confirms it maps 1:1 onto the existing `SymphonyElixir.Tracker.Issue`
struct with no new field. Nothing in this feature changes `Tracker.Issue` itself — see `SPEC.md` §4.1.1 and
`001-local-tracker-multi-agent`'s `data-model.md` §1 for the existing entity this feature reuses without
modification.

## 1. Bindle-Facing Schedulable Projection Record (logical shape, transport TBD — research.md R1)

Owned and published entirely by Bindle. This table describes the **logical** contract a future
Bindle-backed `Tracker` adapter maps onto `Tracker.Issue.t()` — it is not a physical schema, API response
shape, or wire format; those are transport decisions deferred to the eventual implementation feature
(research.md R1).

**Grounded against Bindle's actual implementation (research.md R9, 2026-08-27)**: Bindle's real
`ProjectedWorkItem` (`src/bindle/work_ledger.py:457`) is narrower than this logical table — it carries only
`id`, `title`, `terminal: bool`, `eligible: bool`. Every other row below remains the *logical* contract a
future adapter is entitled to expect if Bindle's projection grows to carry it, but the "Notes" column marks
which fields Bindle actually projects today versus which stay `null`/`[]` on `Tracker.Issue` until a
demonstrated need justifies adding them on Bindle's side.

| Logical Field | Maps to `Tracker.Issue` field | Notes |
|---|---|---|
| Stable schedulable-unit identity | `id` | Identity of the top-level Bindle work unit, stable across projection reads. |
| Native Bindle reference (if any) | `native_ref` | Opaque, non-secret identifier for provider-native agent tools, exactly like every existing adapter. |
| Human-readable identifier | `identifier` | Used for workspace-key derivation, same as every existing adapter. |
| Title / description | `title` / `description` | Same as every existing adapter. Bindle's actual projection currently carries `title` but not `description` (research.md R9) — left `null` until a future revision adds it, if ever demonstrably needed. |
| Priority | `priority` | Same `1..4`-ranks-before-`null` convention as every other adapter (`SPEC.md` §11.3). Not currently projected by Bindle's actual implementation (research.md R9) — left `null`, same as an unset priority on any other adapter. |
| Lifecycle state | `state` | **Adapter-synthesized, not projected verbatim (research.md R9).** Bindle's actual projection carries no state string — only `terminal`/admission facts (see the Admission row below). A future adapter derives a `state` string from those facts against the target `WORKFLOW.md`'s configured `active_states`/`terminal_states`, exactly like every other adapter already interprets its own provider-native state — but here there is no provider-native string to start from, only booleans to map. |
| Branch name | `branch_name` | Same as every existing adapter. Not currently projected by Bindle's actual implementation (research.md R9) — left `null`. |
| URL (if any) | `url` | Bindle MAY synthesize a reference URL or leave `null`, same latitude every adapter has. Not currently projected (research.md R9) — left `null`. |
| Assignee | `assignee_id` | Same as every existing adapter. Not currently projected (research.md R9) — left `null`; Bindle's claim model (`work_item_claims`) exists internally but is not yet surfaced through the projection. |
| Labels | `labels` | Same as every existing adapter. Not currently projected (research.md R9) — left `[]`. |
| Blocking references (to *other visible* projection records only) | `blocked_by` | Informational only, per the existing `Tracker.Issue` contract — never the sole admission gate (see §2 below, research.md R5). A blocking reference to an item that is not itself independently schedulable (and therefore not in the projection) is Bindle's concern to resolve into this item's own admission fact, not something Symphony is given a dangling reference to. |
| **Admission fact** | `dispatchable` | REQUIRED, precomputed entirely by Bindle from its richer internal state (dependencies, claims, execution state, evidence, reconciliation state). Symphony consumes this verbatim — it MUST NOT be derived, cross-checked, or recomputed on the Symphony side (spec FR-003). Grounded directly: Bindle's actual `ProjectedWorkItem.eligible` (`src/bindle/work_ledger.py:457`) is exactly this fact — computed fresh per call from `status`/claim/blocking state, delivered as one ready-made boolean (research.md R9). |
| Timestamps | `created_at` / `updated_at` | Same as every existing adapter. Not currently projected (research.md R9) — left `null`. |

**What is deliberately absent from this table, by design (spec FR-004, FR-011)**: any claim identity,
evidence record, milestone reference, raw dependency-graph edge, reconciliation-state field, or other
Bindle-internal concept. Confirmed directly against Bindle's actual `ProjectedWorkItem` — id/title/terminal/
eligible only, nothing richer (research.md R9). If a future concrete design finds it needs to add a field
beyond this table to satisfy a demonstrated Symphony-side requirement, that is itself a signal requiring a
spec amendment to this feature (a new FR), not a silent schema addition during implementation.

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
  still appear in the projection (with `blocked_by` populated and `dispatchable: false`), rather than being
  removed from the projection outright. Both representations (omit entirely, or include as
  non-dispatchable) satisfy spec FR-002; the eventual implementation feature confirms which one Bindle
  actually produces.

Symphony's read side requires no change to support either representation: `Tracker.Issue.routable?/2`
already gates on `dispatchable` first (`tracker/issue.ex`), so a non-dispatchable member record is already
correctly excluded from scheduling today, with no Bindle-specific logic required.

## 3. Bindle-Backed Tracker Adapter (future, out of scope for this feature's implementation — research.md R3)

Not built by this feature. Sketched here only so the data model above has a concrete consumer to reference:
a future `SymphonyElixir.Tracker`-behaviour-implementing module, structurally identical in shape to
`SymphonyElixir.Local.Adapter` (same six callbacks: `fetch_issues_by_states/1`, `fetch_issues_by_ids/1`,
`agent_tool_specs/0`, `execute_agent_tool/3`, `secret_environment_names/1`, `validate_config/1`), reading
only the projection in §1 and writing only through a Bindle-owned write path (research.md R2) scoped to the
current session's bound item (spec FR-010) — never a second, richer read/write surface.

## 4. Symphony Standalone Local Tracker (existing, unmodified — `001-local-tracker-multi-agent`)

No change to `Local.Store`'s schema, queries, or behavior. The only change this feature makes anywhere in
that module is a moduledoc/comment correction (spec FR-014, research.md R8, `plan.md`'s Project Structure)
removing language that described its `work_item_projection` view as a future Bindle-model growth boundary.
`work_items`, `work_item_projection`, and every existing field remain exactly as `001-local-tracker-multi-agent`
already specifies and implements them.
