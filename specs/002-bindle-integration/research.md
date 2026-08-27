# Phase 0 Research: Bindle-Backed Work Tracking

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

No `[NEEDS CLARIFICATION]` markers remained in the Technical Context or the spec, so this research pass
resolves the investigation questions raised in the originating request instead of clarification markers —
each decision below states what is settled now, what is deliberately deferred to a future implementation
feature's own planning stage, and why.

**Grounding update (2026-08-27)**: R1, R2, R4, and R5 below were re-checked directly against Bindle's own
actual implementation (`~/Developer/bindle`, HEAD `3dddedb`, `specs/001-durable-work-ledger/` +
`specs/002-milestone-task-work-items/`, `src/bindle/work_ledger.py`, `docs/SYMPHONY.md`, `docs/DECISIONS.md`
D037/D038) rather than left as pure speculation about an unbuilt system. No FR changed as a result — the
architecture this spec settled on converges with what Bindle independently built — but several previously
open questions now have real evidence behind them instead of only plausible alternatives, and one concrete
implementation fact (R9 below) was missing from the original design entirely. Where a decision below was
sharpened by this pass, it is marked inline; nothing here retroactively invalidates a prior "deferred to
planning" call — Bindle's own transport and CLI surface for the projection are still genuinely unbuilt.

## R1 — Projection transport mechanism (SQL view vs. query API vs. other)

**Decision**: Still deferred to the eventual Bindle-backed-tracker implementation feature's own planning
stage — Bindle has not built or exposed a transport yet — but now with a stated leaning, not just an open
menu: **favor a CLI-emitted artifact (command output or a generated file) over a direct SQL view into
Bindle's own database**, unless a future concrete design finds a specific reason a view is actually needed.

**Rationale (original)**: Symphony's specification and implementation do not own or control Bindle's
architecture (spec FR-011, Non-Goals). Two structurally different situations are both plausible and require
different transports: an in-process/same-host, SQLite-based Bindle could publish a narrow read-only SQL
view; a separately-deployed Bindle would need a query API. Committing to one transport before either
situation was confirmed would either overconstrain Bindle's own architecture or invent Bindle-internal
detail out of scope here (FR-011).

**Rationale (grounding update)**: Bindle's actual implementation resolves part of this ambiguity even
though no transport is built yet. Bindle's own `specs/001-durable-work-ledger/contracts/coordinator-projection.md`
describes the projection itself, in Bindle's own words, as *"a generated, disposable file (or command
output)"* — not a live view. More decisively, `docs/DECISIONS.md` D014 ("Blocks and pointers, never
private-store parsers") is a standing, repo-wide Bindle principle that no Bindle code may parse another
provider's private store, and by the same replaceability logic Bindle is unlikely to want a foreign process
(Symphony) parsing *its own* private SQLite ledger directly either — `WorkLedger.generate_projection()`
(`src/bindle/work_ledger.py:1326`) is a Python method returning an in-memory list of
`ProjectedWorkItem` dataclasses (`src/bindle/work_ledger.py:457`), not a database view, and nothing in
Bindle's `src/bindle/cli.py` exposes it yet. This doesn't settle the question (Bindle could still choose to
publish a SQL view deliberately), but it means "CLI-emitted artifact" is the transport Bindle's own
implementation shape and stated principles currently point toward, not merely one of two symmetric
possibilities — the eventual implementation feature should treat a SQL view as the alternative needing
justification, not the default.

**Alternatives considered**: Mandating a SQL-view transport now, by direct analogy to `Local.Store`'s own
`work_item_projection` — rejected: conflates the two systems (the exact drift FR-014 corrects) and
presumes a same-process/same-host relationship between Symphony and Bindle that is not established anywhere
in this specification's scope, and is now also in tension with Bindle's own D014 principle above.

## R2 — Coupling risk of direct read/write database access

**Decision**: Split by read vs. write, and treated as a hard constraint, not merely a preference:

- **Reads MAY**, if Bindle chooses a SQLite-based transport per R1, go through a Bindle-published, narrow,
  read-only view scoped to exactly the projection's fields — never ad hoc read access to Bindle's own
  internal tables (ledger, claims, evidence, dependency graph). This mirrors the same discipline
  `Local.Store`'s own `work_item_projection` view already applies internally to `work_items`, just
  published across the Symphony/Bindle boundary instead of within one module.
- **Writes MUST NOT** be a direct database mutation performed by Symphony's OS process against a
  Bindle-owned database file, under any transport choice. Symphony's tracker-write boundary (`FR-009`,
  `FR-010`) calls into a Bindle-owned write path (an API, CLI, or other mechanism Bindle exposes) —
  never a raw `UPDATE`/`INSERT` issued by Symphony's own process against Bindle's storage. This is what
  "no shared mutable database ownership" (spec Non-Goals) concretely rules out.

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

## R9 — Concrete field shape and evidence maturity, grounded against Bindle's actual implementation (2026-08-27)

**Finding**: Bindle's `ProjectedWorkItem` (`src/bindle/work_ledger.py:457`) is deliberately narrower than
data-model.md §1's logical field table assumed in one specific way that matters for a future adapter, plus
one maturity gap worth recording honestly:

1. **No `state` string is projected.** `ProjectedWorkItem` carries exactly `id`, `title`, `terminal: bool`,
   `eligible: bool` — its own docstring says this is deliberate ("coordinator-agnostic: no Symphony-specific
   field names, no `active_states`/`terminal_states` strings"). data-model.md §1's "Lifecycle state → `state`"
   row assumed Bindle would hand across a state string directly; it will not. A future Symphony-side adapter
   must *synthesize* `Tracker.Issue.state` from the `(terminal, eligible)` pair against whatever
   `active_states`/`terminal_states` strings the target `WORKFLOW.md` declares — e.g. `terminal: true` maps
   to a configured terminal-states member, `eligible: true` maps to a "ready" active-states member, and
   `terminal: false, eligible: false` (blocked or claimed) must map to some *other* active-states member,
   never a string absent from both configured sets. This last point is not a new invention — it is exactly
   the "no third withheld status" finding Bindle's own
   `specs/001-durable-work-ledger/contracts/coordinator-projection.md` already documented from Symphony's
   `orchestrator.ex` before any of this was implemented.
2. **No `branch_name`/`url`/`labels`/`priority`/`description` are projected either.** Confirms, rather than
   contradicts, the original contract's "not load-bearing" finding — Bindle's implementation chose to omit
   them entirely rather than emit null placeholders. A future adapter leaves the corresponding
   `Tracker.Issue` fields at their default (`nil`/`[]`); nothing here requires Bindle to add them.
3. **Evidence recording is provenance today, not mechanical verification.** `add_evidence()`/
   `has_qualifying_evidence()` (`src/bindle/work_ledger.py:1075-1116`) only record and check the *presence*
   of an operator-or-agent-asserted pointer (`kind` ∈ `branch`/`commit`/`pull_request`/`other`, a free-text
   `value`) — nothing yet mechanically confirms the referenced commit exists, that a required file actually
   changed, or that a test actually ran and passed. This is earlier-stage than spec FR-012's description of
   what Bindle mechanically verifies, but it is not a contradiction: Bindle's own `PLAN.md` lists deterministic
   evidence emission as upcoming (M1), not yet built, and FR-012 already only constrains *where* such
   verification lives (entirely inside Bindle) once it exists, not a claim that it exists today.

**Decision**: Update data-model.md §1's `state` row and the "What is deliberately absent" note to reflect
(1); no FR changes — FR-002/FR-003/FR-012 already accommodate all three findings as written, since none of
them required a literal state string, extra fields, or fully-built mechanical verification to hold.

**Alternatives considered**: Asking Bindle to add a `state` string to `ProjectedWorkItem` for Symphony's
convenience — rejected: would reintroduce Symphony-specific vocabulary into Bindle's coordinator-agnostic
projection type, which `ProjectedWorkItem`'s own docstring explicitly rejects; the synthesis belongs on
Symphony's adapter side, which already owns `active_states`/`terminal_states` interpretation for every other
adapter today.
