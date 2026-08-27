# Phase 0 Research: Bindle-Backed Work Tracking

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

No `[NEEDS CLARIFICATION]` markers remained in the Technical Context or the spec, so this research pass
resolves the investigation questions raised in the originating request instead of clarification markers —
each decision below states what is settled now, what is deliberately deferred to a future implementation
feature's own planning stage, and why.

**Grounding update (2026-08-27)**: R1, R2, R4, and R5 below were re-checked directly against Bindle's own
actual implementation (`~/Developer/bindle`, HEAD `3dddedb`, `specs/001-durable-work-ledger/` +
`specs/002-milestone-task-work-items/`, `src/bindle/work_ledger.py`, `docs/SYMPHONY.md`, `docs/DECISIONS.md`
D037/D038) rather than left as pure speculation about an unbuilt system. Several previously open questions
now have real evidence behind them instead of only plausible alternatives.

**Rework (2026-08-27, later same day)**: A second pass corrected two conclusions from the grounding update
above that turned out to be wrong calls, not merely refinements — R1's "favor a CLI-emitted artifact"
leaning is **reversed** (see R1 below), and R9's "synthesize `state` from `(terminal, eligible)`" finding is
**superseded** by a corrected projection field shape that carries a native `status` string directly (see R9
below). This rework also adds R10, a genuine gap neither the original design nor the grounding update
identified: Symphony has no durable acquisition/claim seam at all, and Bindle's own real claim mechanism
requires one. Both corrections and the new finding were produced by independent research forks and
adversarial critique passes in this session, not by re-reading the same evidence more carefully — see each
section's "Rework" note for what specifically changed and why.

## R1 — Projection transport mechanism (SQL view vs. query API vs. other)

**Decision (reworked)**: Fixed, not deferred: Bindle MUST publish a **physically separate, read-only SQLite
database artifact** — not a view living inside Bindle's own canonical database file, and not a CLI-emitted
artifact. The previous "favor a CLI-emitted artifact" leaning is reversed. Bindle's own publish mechanics
(refresh cadence, the atomic-rename implementation, where the publish job runs) remain deferred to the
eventual implementation feature — only the artifact's physical *shape* is fixed here.

**Rework rationale (2026-08-27, supersedes the grounding-update rationale below)**: The grounding update's
leaning toward a CLI-emitted artifact rested on two premises that don't hold up under adversarial review:
(1) `docs/DECISIONS.md` D014 ("never private-store parsers") was read as arguing against a SQL-view
transport, but D014's actual concern is a foreign process parsing an *undocumented, private* internal
format — it says nothing against a *deliberately published, versioned, contractual* view, which is a
different category (the same category as a public API); no concrete technical blocker to a SQL-view
transport was found under adversarial critique. (2) `WorkLedger.generate_projection()` being a Python method
today reflects that Bindle hasn't built any transport yet, not evidence that Bindle's team, once it does,
would choose a CLI artifact over a SQL artifact.

A second finding from the same critique pass rules out one specific SQL-view shape: if Bindle published the
projection as `CREATE VIEW schedulable_projection AS ...` **inside its own canonical database file** rather
than a physically separate file, the read boundary this spec requires (R2) would be aspirational, not
structural — SQLite has no per-view access control, so nothing would stop a future code change to Symphony's
adapter from querying `work_items` directly once that same connection is already open. A physically separate
file, published via write-to-temp-then-rename (not relying on WAL, which only protects concurrent readers
within one file, not a cross-file publish), makes the boundary real: Symphony's adapter can literally never
open a connection that also contains Bindle's canonical tables. The published artifact MUST also carry a
schema-version marker (e.g. a `schema_version` row/pragma) Symphony's adapter checks at open time and fails
loud on mismatch, and Symphony's adapter MUST query by column name, never positionally — both needed because
nothing else would detect a Bindle-side schema change (a renamed or reordered column) except a runtime error
or, worse, silent data corruption from a positional read.

**Rationale (grounding update, historical — see rework above for why this leaning was reversed)**: Bindle's
own `specs/001-durable-work-ledger/contracts/coordinator-projection.md` described the projection, in
Bindle's own words, as *"a generated, disposable file (or command output)"* — not a live view. Combined with
`docs/DECISIONS.md` D014, this was read as favoring a CLI-emitted artifact over a SQL view.

**Alternatives considered**: A CLI-emitted artifact (command output or a generated file) — this session's
prior leaning, reversed above; rejected now because it was based on a misapplication of D014 rather than a
genuine blocker, and because a SQL artifact composes more directly with Symphony's existing SQLite-adapter
patterns (`Local.Store`). A SQL view living inside Bindle's own canonical database file (same file, separate
view) — rejected per the boundary-enforceability finding above. Mandating a SQL-view transport by direct
analogy to `Local.Store`'s own `work_item_projection` without addressing the same-file risk — rejected as
incomplete, not as wrong in direction.

## R2 — Coupling risk of direct read/write database access

**Decision**: Split by read vs. write, and treated as a hard constraint, not merely a preference:

- **Reads MUST**, per R1, go through the physically separate, published, read-only projection artifact —
  never ad hoc read access to Bindle's own canonical internal tables (`work_items`, `work_item_blocked_by`,
  `work_item_claims`, `work_item_evidence`). This mirrors the same discipline `Local.Store`'s own
  `work_item_projection` view already applies internally to `work_items`, just published across the
  Symphony/Bindle boundary as a separate artifact instead of a view within one module (R1's boundary-
  enforceability finding is exactly why "within one module" doesn't transfer directly across a process
  boundary).
- **Writes MUST NOT** be a direct database mutation performed by Symphony's OS process against a
  Bindle-owned database file (canonical or published), under any transport choice. Symphony's tracker-write
  boundary calls into a Bindle-owned write path (an API, CLI, or other mechanism Bindle exposes) — never a
  raw `UPDATE`/`INSERT`/`DELETE` issued by Symphony's own process against Bindle's storage. This is what "no
  shared mutable database ownership" (spec Non-Goals) concretely rules out. **Rework note**: this now covers
  three write-shaped obligations, not one — agent-initiated lifecycle mutation (spec FR-009), and the two new
  orchestrator-initiated claim/release calls (spec FR-015/FR-016, see R10) — all three MUST go through a
  Bindle-owned supported operation, never raw SQL, but the two categories are otherwise kept distinct (who
  initiates the write, and what it's scoped to) rather than collapsed into one write API.

**Rationale**: A read-only, explicit, versioned view is a genuine narrow seam — the same pattern this
codebase already trusts internally (`Local.Store`). A write path that lets two independently-deployed
systems mutate the same database file is a different and much riskier kind of coupling (schema-version
skew, write-time invariants only one side knows about, crash-consistency across two OS processes) that the
originating request explicitly asked to avoid. Treating reads and writes asymmetrically resolves the
question without inventing Bindle's write mechanism.

**Grounding update**: Bindle's own `docs/DECISIONS.md` D014 independently reaches the same conclusion from
Bindle's side of the seam — "no Bindle code may parse another provider's private or internal datastore";
Bindle "may call supported interfaces, emit portable blocks that other systems embed, hold pointers that
owning systems resolve." This is the write-side constraint here applied symmetrically: just as Symphony must
not write directly into Bindle's database, Bindle's own stated principle is that it would not expect to
parse or write into another system's private store either. The two specs independently arrived at the same
"supported interface, never private-store access" rule from opposite sides — reinforcing rather than
changing this decision.

**Alternatives considered**: Direct read/write SQLite access for both directions — rejected per the above.
A message queue or event-sourcing layer between the two systems — rejected: no requirement in this spec
demonstrates a need for that machinery, and it would violate spec Non-Goals ("no unnecessary new
infrastructure").

## R3 — New adapter vs. extending `Local.Store`

**Decision**: A new, separate `Tracker` adapter — never an extension of `Local.Store`/`Local.Adapter`.
Confirmed as the correct default, not merely assumed.

**Rationale**: `Local.Store` owns Symphony's own durable local data with its own establishment/corruption
semantics (`001-local-tracker-multi-agent` FR-013). Teaching it about Bindle would (a) recreate exactly the
conflation FR-014 exists to remove, (b) couple two independently-evolving systems' lifecycles inside one
module, and (c) violate Constitution Principle II (Minimize Fork Delta) by modifying an existing,
already-tested adapter instead of adding a new, independent one — the same additive pattern every existing
adapter (`github`, `gitlab`, `jira`, `linear`, `asana`, `local` itself) already follows relative to
`Tracker.@adapters`.

**Alternatives considered**: Adding a `bindle`-aware branch inside `Local.Store` gated by config — rejected,
directly contradicts FR-014 and Constitution II. A shared "SQL-tracker" abstraction parameterized over
schema — rejected as unnecessary abstraction (Constitution V); no two concrete schemas exist yet to
generalize over, and `Local.Store`'s schema is Symphony's own, not shared.

## R4 — Configuration selection mechanism

**Decision**: A new, distinct `tracker.kind` value (exact string deferred to the implementation feature —
e.g. `"bindle"`), following the precedent `001-local-tracker-multi-agent` set when it added `"local"` to
`Tracker.@adapters`. Bindle-specific settings live under `tracker.provider.*`, sibling to how the local
tracker's `path` key already works — exact key names deferred.

**Rationale**: This reuses an existing, proven extension point (`Tracker.@adapters`, `tracker.kind`,
`tracker.provider`) with zero new configuration surface at the schema level — only new values within
surfaces that already exist. Satisfies spec FR-005/FR-006 (single active source, unambiguous selection)
using the mechanism already in place.

**Alternatives considered**: A separate top-level config section (e.g. `bindle: {...}`) outside the
existing `tracker` namespace — rejected: would create a second, competing way to select a work-tracking
source, contradicting the single-active-source model (FR-005) and the existing `tracker.kind` pattern every
other adapter uses.

**Grounding update**: `src/bindle/cli.py` has no Symphony-facing subcommand or wiring at all yet — `bindle
init`/`bindle status` do not touch Symphony (`docs/SYMPHONY.md`'s own "Non-scope" section confirms this
explicitly, and D037 records it as a deliberate, not accidental, gap). This confirms deferring the exact
`tracker.kind` value and `tracker.provider.*` keys was correct rather than merely cautious — there is
nothing on the Bindle side yet to name them after.

## R5 — Projection membership vs. `dispatchable` admission

**Decision**: Two independent, orthogonal gates, exactly as specified in spec FR-002/FR-003 — not
collapsed into one:

1. **Membership**: whether a Bindle item appears in the projection at all. Bindle-owned; determined by
   whether the item is a top-level, independently schedulable unit. Nested/evidence-only/reconciliation-only
   items never appear, regardless of any other state.
2. **Admission (`dispatchable`)**: for items that do appear, whether they are currently eligible for
   dispatch. Bindle-owned; supplied as a precomputed fact on each projection record, exactly like every
   existing adapter's `dispatchable` field (the local tracker's own precedent: always `true`, computed
   once, never re-derived by Symphony — `001-local-tracker-multi-agent` data-model.md §1, research.md R11).

**Rationale**: This is the same two-axis shape `Tracker.Issue` already has today (`blocked_by` +
`dispatchable` are already independent fields; no adapter derives one from the other today). Bindle simply
becomes another producer of both fields using its own richer state internally — Symphony's read side does
not change at all.

**Alternatives considered**: A single boolean collapsing "blocked" and "not independently schedulable" into
one flag — rejected: loses the distinction between "temporarily ineligible, still worth showing progress
on" and "not a schedulable unit in the first place," which the existing `blocked_by` (informational) vs.
`dispatchable` (gating) split already preserves for every other adapter.

**Grounding update**: Bindle's `WorkLedger.generate_projection()` (`src/bindle/work_ledger.py:1326`)
implements exactly this two-axis shape, independently derived. Membership is a hard `WHERE wi.archived_at IS
NULL AND wi.type = 'task'` predicate — a `type = 'milestone'` row can never reach the query result, matching
`specs/002-milestone-task-work-items/contracts/coordinator-projection-v2.md`'s own framing: *"Milestones are
never inputs to the projection at all."* Admission is a separate, single computed boolean
(`eligible`) in the same `SELECT`, `true` iff `status = 'open' AND` not currently claimed `AND` not still
blocked — supplied to the caller as one ready-made fact per row, exactly as this decision requires; nothing
in Bindle's own `ProjectedWorkItem` dataclass asks a consumer to inspect blocking or claim state itself. One
concrete difference from what this decision (and data-model.md §1) originally assumed is captured separately
in R9 below: Bindle's actual `eligible` is a live-computed value returned once per call, not a stored column
the way `Local.Store`'s own `dispatchable` column is — a difference in mechanism, not in the contract
Symphony's side receives.

## R6 — Mechanical evidence boundary

**Decision**: Bindle performs all mechanical evidence verification named in the spec (required files
changed, expected tests/checks ran and passed, commits exist, artifacts produced, dependency/state
transitions internally consistent). Symphony implements none of it and gains no new capability related to
it (spec FR-012).

**Rationale**: This is a direct restatement of Constitution Principle VI (Preserve Execution Boundaries) —
Symphony coordinates work; it does not take on ownership of another system's internal verification logic.
No research is needed on *how* Bindle performs these checks, since that is explicitly Bindle's own concern
(FR-011), not Symphony's.

**Alternatives considered**: None seriously considered — reimplementing any part of this inside Symphony
was rejected outright as scope creep the originating request specifically flagged as a risk to avoid.

## R7 — FR-013-equivalent establishment semantics for a Bindle-backed tracker

**Decision**: Best-effort requirement only (spec FR-007 uses "SHOULD," not "MUST"), left genuinely open.

**Rationale**: `001-local-tracker-multi-agent` FR-013 works because `Local.Store` fully controls its own
establishment marker file. A Bindle-backed tracker's ability to distinguish "never configured" from
"previously working, now failing" depends entirely on what signal Bindle's own projection interface can
supply — a fact this specification cannot determine without knowing Bindle's concrete interface, which is
out of scope here (FR-011). Asserting this is already solved would be exactly the kind of invented
Bindle-internal assumption the spec's Non-Goals prohibit.

**Genuinely unresolved design decision, carried forward explicitly**: The eventual implementation feature's
planning stage MUST confirm what establishment/loss distinction the chosen Bindle-facing interface can
actually provide, and MUST document a real gap here rather than assume parity with FR-013 by default.

## R8 — The `Local.Store` moduledoc correction (FR-014)

**Decision**: Correct `elixir/lib/symphony_elixir/local/store.ex`'s moduledoc (lines ~19–26 as currently
uncommitted) to remove the framing of `work_item_projection` as "the named boundary a future richer,
externally-owned work model... would sit behind," replacing it with a plain statement that `Local.Store` is
Symphony's own standalone, independent local-tracker implementation, and that a future Bindle-backed
tracker (per this feature's spec) would be an entirely separate `Tracker` adapter, not a growth path of
this module or its schema.

**Rationale**: This is the literal, already-confirmed stale assumption the originating request identified.
Leaving it in place would actively mislead a future implementer into extending `Local.Store` for Bindle
support, directly contradicting R3 above and spec FR-014.

**Scope check**: A moduledoc/comment edit describing existing, unmodified behavior more accurately. No
function signature, schema, query, or test changes. Confirmed compatible with the "no implementation code
during the specification phase" guardrail — this is a documentation correction, not new implementation.

## R9 — Concrete field shape, reworked to a native `status` passthrough (supersedes the 2026-08-27 grounding finding)

**Original grounding finding (historical, now superseded)**: Bindle's real, in-process-only
`ProjectedWorkItem` (`src/bindle/work_ledger.py:457`) carries exactly `id`, `title`, `terminal: bool`,
`eligible: bool` — no state string — leading the grounding pass to require a future adapter *synthesize*
`Tracker.Issue.state` from `(terminal, eligible)` against `WORKFLOW.md`'s configured
`active_states`/`terminal_states`.

**Rework (2026-08-27, later same day)**: `ProjectedWorkItem` is Bindle's *current, in-process, unpublished*
return type — it is not the published projection artifact this specification now requires (R1). Since R1
fixes that Bindle must build a new, deliberately published artifact rather than expose `ProjectedWorkItem`
as-is, this is the right moment to fix that artifact's field shape correctly rather than carry forward a
constraint from a type that was never meant to be the external contract. Bindle's own canonical `work_items`
table already has a real `status` column (verified: `open|done|superseded` for tasks) — richer than the
`(terminal, eligible)` pair, and exactly the kind of native state string every other `Tracker` adapter already
hands to Symphony. Requiring Bindle's new publish path to include `status` directly, rather than reducing it
to two booleans and asking Symphony to reconstruct a string from them, is strictly simpler on both sides:
**Decision**: The published projection's field shape is `id, identifier, title, description, status,
dispatchable, created_at` (spec.md Key Entities). `status` maps straight onto `Tracker.Issue.state` with
**no synthesis** — a Bindle-backed `WORKFLOW.md` configures `active_states`/`terminal_states` to literally
name Bindle's own status values (e.g. `active_states: ["open"], terminal_states: ["done", "superseded"]`),
exactly as any other adapter's operator would configure state names today. `dispatchable` replaces
`eligible` as the published admission fact (same computation Bindle already performs — `status = 'open' AND`
not claimed `AND` not blocked — just published as a named boolean column instead of returned inline from a
Python call). `created_at` is added (not part of the original logical table) after tracing
`sort_issues_for_dispatch/1` (orchestrator.ex): it ranks candidates by `(priority_rank, created_at_sort_key,
identifier)`, so omitting `created_at` would collapse every simultaneously-eligible Bindle issue to
alphabetical-by-`identifier` dispatch order — a real, verified behavior change, not a hypothetical one — and
Bindle's `work_items` table already has `created_at`, so including it costs nothing. `identifier` may reuse
Bindle's own `id` (Bindle has no separate human-facing identifier column); verified safe since
`Tracker.Issue.identifier` only needs stability for `workspace_key/1`'s hash, which a stable `TEXT PRIMARY
KEY` satisfies. `priority` is deliberately NOT included — Bindle's `work_items` has no priority column and
none should be invented; Bindle-sourced issues fall back to the existing default priority rank, ordered
secondarily by `created_at` then `identifier`. `branch_name`/`url`/`labels`/`blocked_by`/`assignee_id`/
`updated_at`/`native_ref` remain omitted, left at their existing `Tracker.Issue` defaults — verified, by
direct code audit of `candidate_issue?`, workspace naming, prompt rendering, retries, and reconciliation, to
have zero gating reads outside adapter-internal code or an operator's own optional prompt-template reference.

Evidence recording maturity (Bindle's `add_evidence()`/`has_qualifying_evidence()` recording presence rather
than mechanically verifying claims) is unchanged from the original grounding finding and still holds; FR-012
already only constrains *where* such verification lives once built, not a claim it is fully built today.

**Alternatives considered**: Keeping the `(terminal, eligible)`-synthesis requirement now that a new publish
path is being built anyway — rejected: it would ask every future adapter (not just this one) to carry
Symphony-specific state-mapping logic for no benefit, when Bindle already has a real status string sitting
right there in its own canonical schema. Asking Bindle to add a `state` string to the *existing*
`ProjectedWorkItem` dataclass for Symphony's convenience — still rejected, same as before: that type is
Bindle's own internal, coordinator-agnostic return value: this specification's real correction is not
patching that type, it's requiring Bindle to build the separate published artifact (R1) with a shape
purpose-built for this contract instead.

## R10 — Durable acquisition/claim seam (new, 2026-08-27)

**Finding**: Bindle's canonical model has real, durable, atomically-arbitrated claims —
`work_item_claims(work_item_id PK, owner, claimed_at, worktree_path, branch)`; `claim()`
(`src/bindle/work_ledger.py:966-1016`) is a single `INSERT` arbitrated by the table's own `PRIMARY
KEY(work_item_id)` constraint (concurrent callers race on the constraint; exactly one wins), and
`release_claim(work_item_id, owner)` is an idempotent, owner-scoped `DELETE`. Bindle's own docstring is
explicit: *"a coordinator MUST still attempt claim() before treating an item as acquired"* —
`generate_projection()`'s admission fact is advisory/snapshot only, never a substitute for calling `claim()`.

Symphony's orchestrator today tracks claims **only** in an in-memory `MapSet` (`state.claimed`,
`orchestrator.ex`), with a real, verified race window between reading candidate issues
(`Tracker.fetch_issues_by_states/1`) and actually spawning dispatch (`Task.Supervisor.start_child` inside
`do_dispatch_issue/4`). Nothing in the `Tracker` behaviour today performs or requests durable arbitration,
and no existing adapter (local/GitHub/GitLab/Jira/Linear/Asana) needs to, since none has Bindle's durable,
multi-writer claim model.

**Decision**: Specify a new, narrow, OPTIONAL pair of `Tracker`-behaviour callbacks (spec FR-015/FR-016) —
an acquisition callback called immediately before a candidate is treated as dispatched, and a release
callback called at every point `release_issue_claim/2`/`terminate_running_issue/3` already fire today
(retry-exhausted, terminal transition, routed-away, missing-issue) but *not* merely on a scheduled retry,
since the same workspace/branch is intentionally reused across retry backoff. Optional via
`@optional_callbacks`/`function_exported?/3`, mirroring the existing optional-callback pattern already used
for `agent_tool_specs/0`/`validate_config/1` — every existing adapter is an unconditional no-op.

Two design questions are deliberately left open rather than hand-waved as solved, to be resolved at the
eventual implementation feature's own planning stage:

1. **Call-site timing.** Bindle's `claim()` wants `worktree_path`/`branch`, but the workspace is only
   materialized inside `AgentRunner`, *after* `Task.Supervisor.start_child` already spawned the Task — i.e.,
   after the naive "acquire immediately before spawn" call site. `Workspace.workspace_key/1` is a pure
   function of `identifier` alone, so the path *is* computable earlier if dispatch order is adjusted — but
   this specification does not itself reorder dispatch; that is implementation work.
2. **Crash recovery.** Bindle's claims carry no TTL/lease. If the Symphony BEAM process crashes between a
   successful acquisition and the corresponding work being fully underway, the claim is permanently stranded
   with no automatic release. Fixing this needs new startup-time reconciliation logic (query Bindle for this
   instance's own owner-id claims with no matching in-memory running entry, and release them) — genuine new
   orchestrator-side work, not something the two callback stubs solve by existing.

Also new state, not a reuse of anything existing: an "owner" identity for these calls. Grepped for any
existing per-process/per-instance identity concept in Symphony (`node()`, hostname env, `instance_id`) — zero
hits. `worker_host` is a remote SSH execution target the single Orchestrator dispatches *to*, not a second
independent Symphony instance — there is exactly one Orchestrator process per deployment today, and nothing
in the codebase anticipates two Symphony processes polling the same tracker concurrently. This doesn't make
the seam unnecessary (Bindle's own requirement to call `claim()` is unconditional, regardless of whether
Symphony is single- or multi-instance today), but the spec should not imply "owner" is something already
available to reuse — it must be invented (e.g. a generated/config UUID per deployment).

**Rationale**: This is the one genuinely load-bearing correction to Symphony's own core (the `Tracker`
behaviour itself, plus orchestrator dispatch/release call sites) this rework identified — not hand-waved,
verified against Bindle's actual claim mechanics and Symphony's actual dispatch/release code paths. It does
not teach the orchestrator any Bindle-specific concept: the callback names, arguments, and call sites are
generic and adapter-agnostic; only a Bindle-backed adapter's own *implementation* of the callbacks is
Bindle-specific.

**Alternatives considered**: Treating the projection's `dispatchable` fact as sufficient proof of acquisition
on its own — rejected: directly contradicts Bindle's own explicit requirement and reintroduces the exact
double-dispatch race this seam exists to close. Teaching the orchestrator Bindle's claim semantics directly
(worktree/branch/owner as named orchestrator concepts) — rejected: would violate FR-004's boundary; the
seam's public shape stays generic, with Bindle-specific meaning confined to the adapter's own implementation.
Solving crash recovery now as part of this specification — rejected: doing so would require designing
concrete reconciliation logic against a not-yet-built Bindle write API, which is implementation work for the
eventual feature, not a specification-level decision this document can responsibly settle by itself.
