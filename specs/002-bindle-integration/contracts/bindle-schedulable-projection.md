# Contract: Bindle-Facing Schedulable Projection (logical + physical contract)

This documents the obligations the published projection artifact and the new acquisition/release seam must
satisfy, plus the corrected invariant governing how Symphony may use the projection's `dispatchable` fact
(Continuation obligations, below) — the projection's *physical* shape (a separate SQLite file, specific
columns, opened read-only) is now fixed by this specification (research.md R1, R9); Bindle's own publish
mechanics (refresh cadence, atomic-rename implementation, where the publish job runs) remain an
implementation decision. It exists so a future
implementation feature can be verified against a stable, pre-agreed contract rather than reverse-engineered
from whatever Bindle happens to expose first. Follows the same adapter-profile-documentation spirit
`SPEC.md` §11.2 requires of every concrete tracker adapter, one level up: this documents what the
*projection and acquisition seam* must guarantee, before any adapter is written against it.

## Who owns what

- **Bindle** owns: the durable implementation ledger, all richer state (slices, dependencies/blocking,
  claims, execution state, evidence, reconciliation state), the mechanical-evidence verification logic
  (spec FR-012), the projection artifact itself (its membership rules, admission computation, and publish
  mechanics), and its own supported claim/release/lifecycle-write operations.
- **Symphony** owns: a future `Tracker` adapter that reads the projection and maps it 1:1 onto
  `Tracker.Issue.t()` (data-model.md §1), calls the acquisition/release seam (data-model.md §3) for real-time
  dispatch arbitration, and the existing tracker-write boundary through which scoped lifecycle mutations are
  requested (spec FR-009, FR-010) — never a second read/write path into Bindle's own storage.

## Membership obligations (spec FR-002)

The projection MUST include a record for a Bindle work item **if and only if** that item is a top-level,
independently schedulable implementation unit. The projection MUST NOT include a record for an item that is:

- nested under another (larger) work unit,
- evidence-only,
- reconciliation-only, or
- otherwise not independently schedulable by Bindle's own definition.

This is a hard exclusion, not a filter Symphony is expected to apply — Symphony's adapter has no visibility
into *why* an item is excluded, only that excluded items never appear. **Already satisfied by Bindle's
actual implementation logic** (though not yet exposed through any published artifact): `WorkLedger.
generate_projection()` filters to `WHERE ... wi.type = 'task'` (`src/bindle/work_ledger.py:1326`), so
Bindle's `type = 'milestone'` work items (its own nested/human-acceptance grouping unit) can never appear —
a `WHERE` predicate, not a bypassable convention (research.md R5, R9). The published artifact this contract
requires MUST preserve this same predicate.

## Transport obligations (research.md R1) — CORRECTED

Bindle MUST publish the projection as a **physically separate, read-only SQLite database file** — never a
view or table living inside Bindle's own canonical database file. This is a structural requirement, not a
preference: SQLite has no per-view access control, so a view co-located with Bindle's canonical tables in
one opened connection is an aspirational boundary at best — nothing stops a future code change from
querying `work_items` directly once that connection is open. A physically separate file makes Symphony's
adapter structurally unable to reach Bindle's canonical tables, because it never opens a connection that
contains them.

- The artifact MUST be published atomically (write-to-temp-then-rename, not an in-place rewrite) so a reader
  never observes a torn or partial file mid-publish. WAL mode alone does not solve this for a
  physically-separate-file transport — WAL protects concurrent readers within one file, not a cross-file
  publish.
- The artifact MUST carry a schema-version marker (e.g. a `schema_version` row or SQLite `user_version`
  pragma) that Symphony's adapter checks at open time, failing loud on a mismatch.
- Symphony's adapter MUST query the artifact by column name, never positionally, and MUST validate the
  schema-version marker before treating an opened file as a valid published projection — this also guards
  against a misconfigured `tracker.provider.path` pointing at Bindle's canonical file by mistake.
- **This corrects the previous draft's "favor a CLI-emitted artifact" leaning.** That leaning was grounded
  in Bindle's `docs/DECISIONS.md` D014 ("never private-store parsers"), which was a misapplication: D014's
  concern is a foreign process parsing an undocumented, private internal format — it does not describe a
  deliberately published, versioned, contractual artifact, which is a different category (the same category
  as a public API). No concrete technical blocker to a SQL-artifact transport was found under adversarial
  review (research.md R1).
- Bindle's own publish mechanics (refresh cadence, where the publish job runs, how atomicity is
  implemented) remain deferred to the eventual implementation feature — only the artifact's physical shape
  (separate file, read-only, schema-versioned) is fixed here.
- **Symphony's adapter MUST open the published artifact using SQLite's own read-only open mode** (e.g. a
  read-only connection/URI such as `mode=ro`). Physical separation from Bindle's canonical file structurally
  prevents the adapter from ever reaching Bindle's canonical tables, but does not by itself make the artifact
  read-only to Symphony's own process — nothing about a physically separate file stops a write statement
  from being issued against it. Application-level read-only open semantics are therefore the enforced
  requirement, not merely an adapter implementation that happens never to issue a write statement. Symphony's
  adapter MUST NOT create, migrate, or repair this artifact file under any circumstance; Bindle alone owns
  its publication and replacement.

## Field obligations (data-model.md §1)

The published artifact's columns are fixed as: `id, identifier, title, description, status, dispatchable,
created_at`. Every column maps 1:1 onto an existing `Tracker.Issue` field with no lossy or extended
transform, and the artifact MUST NOT expose any Bindle-internal concept (claim identity, evidence record,
milestone reference, raw dependency-graph edge, reconciliation-state field) that has no corresponding
`Tracker.Issue` field. If a future concrete implementation finds a genuine need for a column beyond this
list, that need MUST be captured as a spec amendment to this feature (a new FR), not introduced silently
during implementation.

- **`status` maps directly onto `Tracker.Issue.state` with no synthesis** — this corrects the previous
  draft's requirement to synthesize `state` from a `(terminal, eligible)` boolean pair. Bindle's own
  `work_items.status` column (task values: `open`/`done`/`superseded`) is projected verbatim. A Bindle-backed
  `WORKFLOW.md` configures `active_states`/`terminal_states` to literally name these values.
- **`dispatchable` replaces the previous `eligible` framing** — same underlying computation
  (`status = 'open' AND` not claimed `AND` not blocked), published as a named boolean column instead of
  returned inline from an in-process call.
- **`created_at` is a new addition**, required because Symphony's existing `sort_issues_for_dispatch/1`
  ranks candidates by `(priority_rank, created_at, identifier)` — omitting it collapses dispatch order among
  simultaneously-eligible Bindle items to alphabetical-by-`identifier`, discarding real signal Bindle can
  supply cheaply.
- All other optional `Tracker.Issue` fields (`native_ref`, `priority`, `branch_name`, `url`, `labels`,
  `blocked_by`, `assignee_id`, `updated_at`) are NOT columns in this artifact and MUST default to their
  existing `Tracker.Issue` empty value (`nil`/`[]`) rather than being invented by the adapter — verified by
  direct code audit that none of them gate any dispatch/candidacy/reconciliation decision.

## Admission obligations (spec FR-003, data-model.md §2)

Every record the projection does include MUST carry a precomputed `dispatchable` boolean fact. This fact:

- MUST be computed entirely on the Bindle side, from whatever richer state Bindle owns (dependencies,
  claims, evidence, reconciliation state, execution state).
- MUST NOT require the Symphony-side adapter to inspect, interpret, or combine any other field to determine
  eligibility — the adapter reads this one fact and passes it straight through onto `Tracker.Issue.dispatchable`.
- MAY be `false` for a member record (e.g., a top-level unit currently blocked by an unresolved dependency);
  membership and admission are independent (data-model.md §2).
- Is a point-in-time snapshot as of the projection's last publish and MAY be stale by the time Symphony
  actually attempts to dispatch — this is exactly why the acquisition obligations below exist as a separate,
  real-time step, not because Symphony second-guesses this fact itself.

## Continuation obligations (spec FR-017, data-model.md §2, research.md R11) — NEW

`dispatchable` (above) is a start/admission gate only. Symphony's own reconciliation logic MUST NOT treat it
as a continuation or preemption gate for an item Symphony has already begun executing or already holds a
claim/block entry for:

- Once Symphony has begun dispatching an item, that item's `dispatchable` fact flipping to `false` on a
  subsequent projection refresh MUST NOT, by itself, cause Symphony to terminate the running agent, release
  the held claim, or end a multi-turn agent run early.
- This is not a hypothetical: because `dispatchable` is computed as "not currently claimed" (Admission
  obligations above), the ordinary, successful claim-then-dispatch sequence required by the
  Acquisition/release obligations below means the item Symphony itself just claimed and started executing
  will correctly report `dispatchable: false` on the very next refresh. Bindle reporting this honestly is
  expected, ordinary behavior, never a fault Symphony should react to by abandoning its own just-started work.
- Symphony's existing termination/release triggers for an already-running or already-blocked item — terminal
  state, the item leaving the active-state set, or the item disappearing from the tracker's visible set —
  are unaffected by this obligation and remain in force exactly as for every other tracker.
- This obligation is generic to Symphony's own reconciliation logic, not a Bindle-specific carve-out; it
  applies identically to any tracker whose `dispatchable` computation can be affected by Symphony's own
  claim state.

## Acquisition/release obligations (spec FR-015/FR-016, data-model.md §3) — NEW

Bindle's canonical claim mechanism (`work_item_claims`, atomically arbitrated by a primary-key constraint)
requires a coordinator to call `claim()` before treating an item as acquired — the projection's `dispatchable`
fact above is advisory only and MUST NOT be treated as sufficient proof of acquisition on its own.

- Symphony's `Tracker` behaviour MUST expose one narrow, OPTIONAL pair of callbacks (an acquisition callback
  and a release callback) that a Bindle-backed adapter implements to call into Bindle's own supported
  `claim()`/`release_claim()`-equivalent operations.
- The orchestrator MUST call the acquisition callback, when the active adapter implements it, immediately
  before treating a candidate issue as dispatched, and MUST skip dispatching that issue in the current cycle
  on any result other than success.
- The orchestrator MUST call the release callback, when the active adapter implements it, at every existing
  point it releases its own in-memory claim today (retry-exhausted, terminal-state transition, routed-away,
  missing-issue detection) — and MUST NOT call it merely because a retry is being scheduled.
- Both callbacks MUST be a complete no-op, with zero behavior change, for any adapter that does not
  implement them (every adapter existing as of this specification).
- These calls are scoped exclusively to claim/release — they MUST NOT read or write any lifecycle-state
  field, and MUST NOT be satisfied by a raw SQL mutation against any Bindle-owned database file (spec
  FR-016); they are a distinct, narrower category of orchestrator-owned write from the agent-initiated
  lifecycle mutations governed by the Write obligations below.
- **This contract deliberately does NOT resolve**: (a) the dispatch-order/call-site timing needed to supply
  Bindle's actual claim parameters (`worktree_path`/`branch`), since the workspace path is only materialized
  after a Task is already spawned today; (b) crash-recovery reconciliation for a Symphony instance's own
  claims stranded by a crash between successful acquisition and the work being fully underway, since
  Bindle's claims carry no TTL/lease; (c) the concrete "owner" identity value these calls use, since no
  per-instance identity concept exists in Symphony today. All three are genuinely open design questions the
  eventual implementation feature's planning stage MUST resolve, not assumed solved by this contract alone.

## Write obligations (spec FR-009, FR-010, FR-016)

- Symphony MUST NOT perform a direct database mutation against any Bindle-owned storage (canonical or
  published), under any transport choice.
- Every lifecycle-state mutation a coding-agent session performs against a Bindle-managed item MUST go
  through Symphony's existing agent-invoked, host-executed tracker-write boundary (`agent_tool_specs/0` +
  `execute_agent_tool/3`), which in turn calls into a Bindle-owned write path (an API, CLI, or other
  mechanism Bindle exposes — concrete mechanism deferred to the implementation feature).
- Every such mutation MUST be scoped to the work item bound to the current coding-agent session; it MUST
  NOT be able to target an arbitrary Bindle work item (spec FR-010).
- The acquisition/release calls above are a separate, orchestrator-owned category of write, narrowly scoped
  to claim/release operations only (spec FR-016) — this is a deliberate, bounded carve-out from "no new
  orchestrator-owned tracker-write API," not a silent contradiction of it.
- **Bindle now exposes a narrow, supported external write surface for claim/release/done** — re-verified
  2026-08-27 against `~/Developer/bindle` HEAD `d70bc30` (`docs/DECISIONS.md` D039): `claim_task()` /
  `release_task()` / `complete_task()` (library, `src/bindle/symphony_projection.py`) and their
  `bindle work claim` / `release` / `done` CLI equivalents, each a thin wrapper over the ledger's own
  atomic `claim()` / `release_claim()` / `mark_done()` primitives, rejecting a milestone id distinctly
  rather than silently treating it as a task. No general-purpose lifecycle-mutation write beyond these
  three operations exists — this contract's FR-009 lifecycle-write obligation and FR-016's narrower
  claim/release exception both remain correctly scoped: a future Bindle-backed adapter's read of
  "supported write path" now resolves to these three functions, not to an unresolved dependency.
- **`done` is a task-scoped, agent-authorizable write; Bindle's own supported write surface has no
  milestone-acceptance operation for Symphony to call at all (spec FR-013, research.md R16)**: `complete_task()`
  /`bindle work done <id>` categorically rejects a milestone id (`not_a_task`) rather than accepting one, and
  takes no `--owner`/claim argument — Bindle's own model does not gate a task's `done` transition on human
  review (`docs/DECISIONS.md` D038: "readiness is mechanical; acceptance is semantic"). This means an agent's
  FR-009-authorized, session-scoped request to mark its own bound *task* done is squarely inside this
  contract's existing Write obligations (below) — a Bindle-owned supported write operation, scoped to the
  session's bound item — not a new write category. Milestone `accepted` (`accept_milestone()`) has no CLI
  surface this contract or FR-009 authorizes Symphony to call at all; nothing in this specification permits a
  future adapter to invoke it.

## Failure-surface obligations (spec FR-007, FR-008, research.md R7)

- A transient failure to read the projection MUST be distinguishable, from Symphony's side, from a genuine
  read (i.e., Symphony's adapter must be able to return an ordinary tracker/source-fetch error that the
  orchestrator already knows how to handle per its existing tracker/source failure path — spec FR-008). A
  schema-version mismatch on the published artifact (Transport obligations above) MUST be treated the same
  way — fail loud, never silently misread.
- Whether the projection interface can additionally distinguish "never configured" from "previously
  working, now failing" (the FR-013-equivalent distinction spec FR-007 asks for) is **not guaranteed by
  this contract** — research.md R7 leaves this a genuinely open question the implementation feature's
  planning stage must confirm against Bindle's actual interface, and must document honestly if the
  distinction is not available.

## What this contract deliberately does not specify

- Bindle's own publish mechanics for the projection artifact (refresh cadence, atomic-rename
  implementation, where the publish job runs) — the artifact's physical *shape* is fixed (Transport
  obligations above); producing it is Bindle's own implementation.
- The concrete call-site timing, crash-recovery reconciliation design, and owner-identity value for the
  acquisition/release seam (see that section above) — deliberately left to the eventual implementation
  feature's planning stage.
- Whether Bindle's mechanical evidence verification (spec FR-012) is fully built. Bindle's evidence
  mechanism (`add_evidence`/`has_qualifying_evidence`, `src/bindle/work_ledger.py:1075-1116`) only records
  and checks the *presence* of an asserted pointer (branch/commit/pull_request/other) — it does not yet
  mechanically confirm the pointer's claim (that a commit exists, a file changed, a check passed). FR-012
  constrains *where* such verification must live (entirely inside Bindle) whenever it exists; it does not
  claim Bindle has fully built it today.
- Bindle's own internal schema, dependency/claims/evidence model, or reconciliation logic (spec FR-011).
- The exact `tracker.kind` value or `tracker.provider.*` field names a future adapter will use.
- Authentication/authorization between Symphony and Bindle, if a future transport revision introduces a
  network surface — genuinely undecided; this contract's transport (a local, shared-filesystem SQLite
  artifact) does not itself require one.
