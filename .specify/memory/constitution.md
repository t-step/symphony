<!--
Sync Impact Report
- Version change: (unratified template) → 1.0.0
- Rationale: Initial ratification of the Symphony Development Fork Constitution. The file
  previously held only the unfilled Spec Kit scaffold; this is the first substantive adoption,
  not an amendment, so it is versioned as 1.0.0.
- Modified principles: none (first ratification)
- Added principles: I. Inherit Upstream First; II. Minimize Fork Delta;
  III. Preserve Upstream Compatibility; IV. Specification Before Implementation;
  V. Avoid Unnecessary Abstraction; VI. Preserve Execution Boundaries;
  VII. Verify Fork Behavior Without Regressing Upstream
- Added sections: Governance
- Removed sections: none
- Deferred placeholders: none — all template tokens resolved. Optional template sections
  ("Additional Constraints", "Development Workflow") are intentionally omitted rather than
  padded; nothing here requires them.
- Templates requiring follow-up: none checked in this pass (constitution-only session; plan/spec/
  tasks templates are validated against this constitution when the next feature is specified).
-->

# Symphony Development Fork Constitution

This constitution governs how the maintained Symphony development fork evolves relative to
upstream Symphony. It does not define concrete fork behavior — that belongs to the
fork's own specification once written — and it does not restate or replace upstream Symphony's
own project rules.

## Core Principles

### I. Inherit Upstream First

Upstream Symphony architecture and behavior are the default and MUST be preserved unless a
deliberate development requirement calls for a difference. Fork changes MUST prefer existing
Symphony seams and contracts over replacing core orchestration machinery. The fork does not
restate or reimplement upstream behavior it already inherits for free.

### II. Minimize Fork Delta

Development-specific changes MUST stay as small and localized as practical. Prefer additive
adapters or narrow extensions over changes to scheduler semantics, reconciliation, retry/backoff
behavior, workspace lifecycle, observability, or other unrelated upstream components. When two
designs would produce equivalent behavior, the one with the smaller maintained delta MUST be
preferred.

### III. Preserve Upstream Compatibility

Fork changes MUST remain easy to understand against upstream, rebase onto newer upstream
versions, test independently, and remove once equivalent support lands upstream. Repository-wide
refactors that only normalize or generalize the fork, with no upstream-compatibility or
specification benefit, are not permitted.

### IV. Specification Before Implementation

Once written, the fork's development specification is authoritative for fork-specific behavior.
Prior prototypes or exploratory implementations are evidence that informs the specification, not
requirements it must satisfy. Implementation MUST be reconciled against the reviewed
specification, not the other way around.

### V. Avoid Unnecessary Abstraction

The fork MUST NOT introduce new orchestration frameworks, lifecycle ontologies, graph/DAG models,
provider frameworks, generic plugin systems, or distributed coordination machinery unless a
demonstrated requirement makes one necessary. Always prefer the smallest concrete seam that
satisfies the specification over a more general one.

### VI. Preserve Execution Boundaries

Top-level coordination and coding-agent execution are separate concerns. Symphony MUST coordinate
work without taking on ownership of the coding agent's internal planning, model behavior,
subagents, or tools. Provider-specific behavior MUST stay localized to its execution integration
rather than leaking into core coordination.

### VII. Verify Fork Behavior Without Regressing Upstream

Fork-specific behavior requires focused tests before it is considered done. Existing upstream
behavior MUST continue to pass upstream's canonical checks. A change to core upstream semantics
requires stronger evidence before it can land than an additive adapter change does.

## Governance

This constitution supersedes conflicting fork-specific practices for how the fork evolves
relative to upstream Symphony. It does not govern upstream Symphony's own project rules, which
remain out of scope for this document.

Amendments require:

- A documented rationale naming which principle is added, changed, or removed, and why.
- A version bump under the policy below.
- Review by the fork's maintainer(s) before the amendment lands.

Versioning policy (semantic versioning applied to this document):

- MAJOR: backward-incompatible principle removal or redefinition.
- MINOR: a new principle added, or an existing principle materially expanded.
- PATCH: wording, clarification, or other non-semantic edits.

Compliance review: a change proposed to core upstream semantics (scheduler, reconciliation,
retry/backoff, workspace lifecycle, observability, or another unrelated upstream component) MUST
cite which principle above justifies the deviation before it is accepted.

**Version**: 1.0.0 | **Ratified**: 2026-08-25 | **Last Amended**: 2026-08-25
