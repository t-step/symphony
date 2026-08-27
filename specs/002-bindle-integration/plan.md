# Implementation Plan: Bindle-Backed Work Tracking Through a Narrow Schedulable Projection

**Branch**: `002-bindle-integration` (Spec Kit feature identifier only; work stays on `development` per the fork's workflow — see `001-local-tracker-multi-agent`) | **Date**: 2026-08-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-bindle-integration/spec.md`

**Note**: This template is filled in by the `/speckit-plan` command; its definition describes the execution workflow.

## Summary

This feature is an architecture/contract specification, not a runtime capability. It fixes the ownership
boundary between Symphony and a future Bindle integration — Bindle owns its durable implementation ledger;
Symphony consumes only a narrow, Bindle-owned schedulable projection through its existing `Tracker`
adapter boundary, producing the existing `Tracker.Issue` shape unchanged — and it defers every Bindle-side
and transport-level decision (projection mechanism, config field names, exact `tracker.kind` value) to the
planning stage of a future, separate implementation feature that builds the actual Bindle-backed adapter.

The only concrete change this plan authorizes now is a narrow, one-file documentation correction: the
moduledoc of `elixir/lib/symphony_elixir/local/store.ex` (feature `001-local-tracker-multi-agent`,
currently uncommitted) describes its `work_item_projection` SQL view as "the named boundary a future
richer, externally-owned work model... would sit behind" — language that conflates Symphony's own
standalone local tracker with a future Bindle-backed tracker merely because both currently happen to use
SQLite. This plan corrects that comment to state plainly that the standalone local tracker is Symphony's
own independent implementation and that a future Bindle-backed tracker would be an entirely separate
`Tracker` adapter, not a growth path of `Local.Store` (spec FR-014). No behavior changes; no test changes
required, since no observable behavior is altered.

## Technical Context

**Language/Version**: Elixir `~> 1.19` (OTP 28), via `mise` — unchanged. This feature makes no code change
beyond the one moduledoc comment correction described above.

**Primary Dependencies**: None added or removed. This feature does not touch `mix.exs`/`mix.lock`. A future
Bindle-backed adapter's dependencies (if any) are out of scope for this plan and belong to the eventual
implementation feature.

**Storage**: N/A for this feature's own scope. Symphony's standalone local tracker storage
(`Local.Store`'s SQLite database, `001-local-tracker-multi-agent`) is unmodified in shape or behavior — only
its moduledoc commentary changes. Bindle's own storage technology and schema are explicitly out of scope
(spec Non-Goals, FR-011) and are not decided, assumed, or constrained by this plan.

**Testing**: `mix test` / `make all`, unchanged toolchain. This feature's one code change is a docstring
edit with no behavioral effect, so no new test is required; the existing `local_store_test.exs`,
`local_adapter_test.exs`, and `local_init_test.exs` suites (`001-local-tracker-multi-agent`) MUST continue
to pass unchanged, verified as part of this feature's own verification (Constitution Principle VII) even
though this feature adds no new test of its own.

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

**Scale/Scope**: One specification, one plan (this document) with its Phase 0/1 design artifacts, and one
one-line-scoped moduledoc correction in existing, already-uncommitted code. Zero new modules. The
eventual Bindle-backed `Tracker` adapter implementation itself is explicitly future work under a separate
feature, not part of this plan's scope or task list.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Checked against `.specify/memory/constitution.md` v1.0.0:

- **I. Inherit Upstream First** — PASS. This feature changes zero orchestration, scheduler, dispatcher, or
  agent-runner behavior; it only fixes documentation and specifies a future adapter's contract in terms of
  Symphony's existing, unmodified `Tracker` behaviour.
- **II. Minimize Fork Delta** — PASS, maximally so: this is the narrowest possible fork delta a Spec Kit
  feature can have — one moduledoc correction, no new modules, no new config surface, no new dependency.
  The future Bindle-backed adapter this spec anticipates is itself scoped, when eventually built, as one
  additive adapter (mirroring `local`/`github`/`gitlab`/`jira`/`linear`/`asana`), not a change to any
  existing adapter or to shared orchestration code.
- **III. Preserve Upstream Compatibility** — PASS. No existing deployment's configuration, behavior, or
  observable output changes as a result of this feature.
- **IV. Specification Before Implementation** — PASS, and this is this feature's entire purpose: it exists
  specifically to put a reviewed specification in place *before* any Bindle-backed adapter implementation
  is attempted, so that implementation is reconciled against this spec rather than against ad hoc
  assumptions or a prior informal design.
- **V. Avoid Unnecessary Abstraction** — PASS. The spec explicitly rejects inventing Bindle-internal
  concepts inside Symphony (claims, evidence, reconciliation, milestones, dependency-graph internals —
  FR-004, FR-011) and rejects committing to a projection transport mechanism before Bindle's own side of
  that mechanism is actually designed (Assumptions) — both are deliberate refusals to abstract prematurely,
  not gaps.
- **VI. Preserve Execution Boundaries** — PASS, and central to this feature: Bindle's mechanical evidence
  verification and richer internal model stay entirely inside Bindle (FR-012); Symphony's orchestrator only
  ever sees the existing `Tracker.Issue` shape through the existing `Tracker` behaviour (FR-001, FR-004).
- **VII. Verify Fork Behavior Without Regressing Upstream** — PASS. The one code change in scope (moduledoc
  correction) requires the existing `001-local-tracker-multi-agent` local-tracker test suites to still pass
  unchanged as verification that no behavior was altered; no new fork-specific runtime behavior is
  introduced by this feature to separately verify.

No violations requiring the Complexity Tracking table.

### Post-Design Re-Check (after Phase 1)

Re-evaluated against `research.md`, `data-model.md`, and `contracts/bindle-schedulable-projection.md` as
actually written.

- Phase 1 design introduces no new orchestrator-facing entity, callback, or module — it only elaborates the
  logical shape of the future Bindle-facing projection and confirms (research.md R3) that a future
  Bindle-backed tracker must be a new, separate `Tracker` adapter rather than an extension of `Local.Store`.
  **I/II/V still PASS** — this re-affirms rather than changes the pre-design gate evaluation.
- research.md R2 makes explicit, as a hard design constraint (not merely a preference), that no future
  Bindle-backed adapter may perform direct mutable writes into a Bindle-owned database file — lifecycle
  writes MUST go through a Bindle-owned write path, never a shared-database write from Symphony's OS
  process. This sharpens spec Non-Goals into an explicit rejected-alternative record without changing any
  FR. **VI still PASS.**
- No violation surfaced during design; Complexity Tracking table remains empty.

### Grounding Re-Check (2026-08-27, after Bindle's actual implementation was inspected)

`research.md` R1, R2, R4, R5 were re-checked directly against Bindle's real implementation
(`~/Developer/bindle`, `src/bindle/work_ledger.py`, `docs/SYMPHONY.md`, `docs/DECISIONS.md` D037/D038), and
a new R9 was added for one concrete gap the original design missed (Bindle's actual projection carries no
`state` string, only `terminal`/`eligible` booleans — a future adapter must synthesize `state`, not receive
it). No Constitution gate result changes: I/II/V/VI's PASS verdicts above hold under the grounded evidence,
and no FR was added, removed, or reworded — only `research.md`, `data-model.md`, and
`contracts/bindle-schedulable-projection.md` were sharpened with confirmed implementation detail in place of
prior speculation. See `research.md`'s "Grounding update (2026-08-27)" note for the full detail.

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

This feature makes exactly one source change and adds no new module, package, or directory:

```text
elixir/
└── lib/symphony_elixir/
    └── local/
        └── store.ex   # EXISTING (001-local-tracker-multi-agent, uncommitted) — moduledoc correction
                        #   only (FR-014): remove language framing `work_item_projection` as a future
                        #   Bindle-model growth boundary; state plainly this is Symphony's own standalone
                        #   local tracker, unrelated to a future Bindle-backed tracker. No code/behavior
                        #   change; no new or modified test.
```

A future, separate implementation feature (out of scope here) would eventually add a new adapter package —
sketched in `data-model.md`/`contracts/bindle-schedulable-projection.md` for continuity, but **not created
by this plan**:

```text
elixir/
└── lib/symphony_elixir/
    └── bindle/                # NOT created by this feature — sketch only, for a future implementation
        ├── adapter.ex          # would implement @behaviour SymphonyElixir.Tracker, mirroring local/adapter.ex
        └── ...                 # supporting modules (naming, count, and shape decided at that feature's own planning stage)
```

**Structure Decision**: This feature is documentation/specification-only against the existing single-project
Elixir layout, plus one moduledoc correction in an already-existing file. No new source tree is created. A
future Bindle-backed `Tracker` adapter would follow the exact same per-adapter package convention every
existing adapter (`local/`, `github/`, `gitlab/`, `jira/`, `linear/`, `asana/`) already uses, registered the
same way in `Tracker.@adapters` — this plan establishes that convention as the expected shape without
creating it, since building it is not this feature's scope.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations. Table intentionally omitted.
