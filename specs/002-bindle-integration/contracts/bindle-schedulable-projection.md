# Contract: Bindle-Facing Schedulable Projection (logical contract)

This is a **logical** contract — the obligations any concrete transport (SQL view, query API, or other
mechanism per research.md R1) must satisfy — not a wire format, API schema, or SQL DDL. It exists so a
future implementation feature can be verified against a stable, pre-agreed contract rather than
reverse-engineered from whatever Bindle happens to expose first. Follows the same
adapter-profile-documentation spirit `SPEC.md` §11.2 requires of every concrete tracker adapter, one level
up: this documents what the *projection* must guarantee, before any adapter is written against it.

## Who owns what

- **Bindle** owns: the durable implementation ledger, all richer state (slices, dependencies/blocking,
  claims, execution state, evidence, reconciliation state), the mechanical-evidence verification logic
  (spec FR-012), and the projection itself — its membership rules, its admission computation, and its
  transport.
- **Symphony** owns: a future `Tracker` adapter that reads the projection and maps it 1:1 onto
  `Tracker.Issue.t()` (data-model.md §1), and the existing tracker-write boundary through which scoped
  lifecycle mutations are requested (spec FR-009, FR-010) — never a second read/write path into Bindle's
  own storage.

## Membership obligations (spec FR-002)

The projection MUST include a record for a Bindle work item **if and only if** that item is a top-level,
independently schedulable implementation unit. The projection MUST NOT include a record for an item that is:

- nested under another (larger) work unit,
- evidence-only,
- reconciliation-only, or
- otherwise not independently schedulable by Bindle's own definition.

This is a hard exclusion, not a filter Symphony is expected to apply — Symphony's adapter has no visibility
into *why* an item is excluded, only that excluded items never appear. **Already satisfied by Bindle's
actual implementation**: `WorkLedger.generate_projection()` filters to `WHERE ... wi.type = 'task'`
(`src/bindle/work_ledger.py:1326`), so Bindle's `type = 'milestone'` work items (its own nested/human-
acceptance grouping unit) can never appear — a `WHERE` predicate, not a bypassable convention, confirmed
directly rather than assumed (research.md R5, R9).

## Admission obligations (spec FR-003, data-model.md §2)

Every record the projection does include MUST carry a precomputed `dispatchable`-equivalent boolean fact.
This fact:

- MUST be computed entirely on the Bindle side, from whatever richer state Bindle owns (dependencies,
  claims, evidence, reconciliation state, execution state).
- MUST NOT require the Symphony-side adapter to inspect, interpret, or combine any other field to determine
  eligibility — the adapter reads this one fact and passes it straight through onto `Tracker.Issue.dispatchable`.
- MAY be `false` for a member record (e.g., a top-level unit currently blocked by an unresolved dependency);
  membership and admission are independent (data-model.md §2).

**Already satisfied by Bindle's actual implementation**: `ProjectedWorkItem.eligible`
(`src/bindle/work_ledger.py:457`) is exactly this fact — `true` iff `status = 'open'` and the item is
currently neither claimed nor still blocked, computed in the same query that determines membership so both
facts are read from one consistent snapshot (research.md R9).

## Field obligations (data-model.md §1)

Every field the projection exposes MUST map 1:1 onto an existing `Tracker.Issue` field with no lossy or
extended transform, and MUST NOT expose any Bindle-internal concept (claim identity, evidence record,
milestone reference, raw dependency-graph edge, reconciliation-state field) that has no corresponding
`Tracker.Issue` field. If a future concrete implementation finds a genuine need for a field beyond
data-model.md §1's table, that need MUST be captured as a spec amendment to this feature (a new FR), not
introduced silently during implementation.

**Concrete adapter obligation, not present in the original abstract contract**: Bindle's actual projection
carries no `state` string — only `id`, `title`, `terminal: bool`, `eligible: bool` (research.md R9). The
future adapter MUST synthesize `Tracker.Issue.state` from `(terminal, eligible)` against the target
`WORKFLOW.md`'s configured `active_states`/`terminal_states`, and MUST NOT produce a state string that is a
member of neither configured set for a non-terminal, non-eligible (blocked/claimed) item — this mirrors the
"no third withheld status" finding Bindle's own `specs/001-durable-work-ledger/contracts/coordinator-projection.md`
already documented against Symphony's `orchestrator.ex`. All other optional fields
(`branch_name`/`url`/`labels`/`priority`/`description`/`assignee_id`/timestamps) are not currently projected
by Bindle and MUST default to their existing `Tracker.Issue` empty value (`nil`/`[]`) rather than being
invented by the adapter.

## Read obligations (research.md R1, R2, R9)

- The projection MUST be read-only from Symphony's perspective, regardless of transport.
- **Favored**: a CLI-emitted artifact (command output or a generated file) — Bindle's own contract language
  describes the projection as "a generated, disposable file (or command output)," and Bindle's `WorkLedger.
  generate_projection()` (`src/bindle/work_ledger.py:1326`) is already shaped as a plain method call
  returning an in-memory list, not a database view; Bindle's `docs/DECISIONS.md` D014 ("never private-store
  parsers") independently argues against exposing raw database access either direction. This is a leaning
  grounded in Bindle's actual implementation and stated principles (research.md R1's grounding update), not
  yet a committed transport — no CLI wiring exists on the Bindle side as of this grounding pass.
- A SQL view remains structurally allowed only if Bindle and Symphony share a process/host boundary and
  Bindle deliberately chooses to publish one; the view MUST then be narrow and MUST expose only the fields
  in data-model.md §1 — never ad hoc read access to Bindle's own internal tables (ledger, claims, evidence,
  dependency graph). Treat this as the alternative needing justification, not the default.
- If Bindle runs as a separate service, the transport MUST be a query API (or equivalent) — a shared SQLite
  file across a process/host boundary is explicitly disallowed (research.md R2, spec Non-Goals: "no shared
  mutable database ownership").

## Write obligations (spec FR-009, FR-010, research.md R2)

- Symphony MUST NOT perform a direct database mutation against Bindle-owned storage, under any transport
  choice.
- Every lifecycle-state mutation Symphony's coding-agent session performs against a Bindle-managed item
  MUST go through Symphony's existing agent-invoked, host-executed tracker-write boundary
  (`agent_tool_specs/0` + `execute_agent_tool/3`), which in turn calls into a Bindle-owned write path (an
  API, CLI, or other mechanism Bindle exposes — concrete mechanism deferred to the implementation feature).
- Every such mutation MUST be scoped to the work item bound to the current coding-agent session; it MUST
  NOT be able to target an arbitrary Bindle work item (spec FR-010).

## Failure-surface obligations (spec FR-007, FR-008, research.md R7)

- A transient failure to read the projection MUST be distinguishable, from Symphony's side, from a genuine
  read (i.e., Symphony's adapter must be able to return an ordinary tracker/source-fetch error that the
  orchestrator already knows how to handle per its existing tracker/source failure path — spec FR-008).
- Whether the projection interface can additionally distinguish "never configured" from "previously
  working, now failing" (the FR-013-equivalent distinction spec FR-007 asks for) is **not guaranteed by
  this contract** — research.md R7 leaves this a genuinely open question the implementation feature's
  planning stage must confirm against Bindle's actual interface, and must document honestly if the
  distinction is not available.

## What this contract deliberately does not specify

- The concrete transport mechanism (research.md R1) — leaning toward a CLI-emitted artifact per Bindle's own
  implementation shape and D014, but not committed; Bindle has not built or exposed one yet.
- Whether Bindle's mechanical evidence verification (spec FR-012) is fully built. As of this contract's
  grounding pass, Bindle's evidence mechanism (`add_evidence`/`has_qualifying_evidence`,
  `src/bindle/work_ledger.py:1075-1116`) only records and checks the *presence* of an asserted pointer
  (branch/commit/pull_request/other) — it does not yet mechanically confirm the pointer's claim (that a
  commit exists, a file changed, a check passed). FR-012 constrains *where* such verification must live
  (entirely inside Bindle) whenever it exists; it does not claim Bindle has fully built it today
  (research.md R9).
- Bindle's own internal schema, dependency/claims/evidence model, or reconciliation logic (spec FR-011).
- The exact `tracker.kind` value or `tracker.provider.*` field names a future adapter will use
  (research.md R4).
- Authentication/authorization between Symphony and Bindle, if the transport is a network API — genuinely
  undecided, since the transport itself is undecided (research.md R1).
