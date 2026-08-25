# Specification Quality Checklist: Local Work Tracking and Selectable Coding-Agent Execution for the Symphony Fork

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-25
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- The three `[NEEDS CLARIFICATION]` markers previously on FR-010, FR-011, and FR-012 are resolved by human-review decisions, incorporated into this revision: (1) FR-010 — a single Symphony deployment has exactly one active coding-agent execution integration at a time (Codex or Claude Code, not both, and no per-work-item runtime routing); teams needing both compose via multiple deployments. (2) FR-011 — local work-tracking source lifecycle mutations flow through Symphony's existing tracker-write boundary (agent-invoked, host-executed tracker tooling), not through new orchestrator-owned tracker-write APIs; implementation mechanics remain unspecified pending planning. (3) FR-012 — a single deployment has exactly one active work-tracking source at a time (the local source or one hosted tracker, never both simultaneously).
- This revision also reframes the feature as intended maintained behavior for the fork (not an experiment, spike, or feasibility trial), corrects FR-002/FR-003 to keep claim/retry/concurrency/priority/scheduler-eligibility as orchestration-owned concerns, tightens FR-008's startup-vs-runtime failure handling, adds FR-013 (local work-tracking state corruption must surface an operator-visible failure, never be silently recreated/truncated/reset), revises IV-004 to require common cross-integration lifecycle observability without mandating identical telemetry shape, strengthens SC-002 to require an actually-demonstrated successful Claude Code run, and rewrites User Story 3 as a normal supported composition rather than a validating experiment. No new clarification questions were introduced.
- A further narrow cleanup pass (same day) applied a second round of human review: retitled the feature "...for the Symphony Fork" (dropping "Development"); rewrote FR-003 so lifecycle-state mutations are described as agent-invoked, host-executed tracker tooling scoped to workflow/business lifecycle progression only, explicitly not required for claiming, retry, reconciliation, or concurrency; relaxed User Story 1's second acceptance scenario so a successful coding-agent session is not required to mutate lifecycle state (a mutation occurs only when the workflow directs one, otherwise the item continues under existing active-item behavior); resolved the two remaining edge-case questions into explicit behavior (no coding-agent execution integration selected -> default to existing Codex behavior; no work-tracking source configured -> configuration is invalid, not a hosted-tracker default); extended IV-005 to define that a mid-flight configuration change binds only future run attempts, leaving an in-flight attempt bound to the tracker/source and execution integration it started with; renamed User Story 3 to "Operate Symphony with Local Work Tracking and Claude Code"; tightened the first Assumptions bullet to drop the feasibility-contingency language; and reworded User Story 2 to avoid phrasing ("a deployment or workflow") that could imply multiple independently configured workflows inside one deployment, in favor of "a deployment, configured through its WORKFLOW.md." No FR/IV/SC numbering changed and no new clarification questions were introduced.
- A final pre-planning review pass (same day) tightened FR-013 to distinguish first-time initialization of a not-yet-established local work-tracking store (permitted; concrete mechanism left to planning) from loss of access to one already established (missing, deleted, or corrupted durable state MUST surface as an operator-visible failure of the work-tracking source itself, distinct from an item-level attempt failure, and MUST NOT be silently recreated, truncated, reset, or treated as a fresh empty source); reworded the two related Edge Cases bullets to remove the prior ambiguity between tolerated transient/temporary read failures and non-tolerated established-state loss, and cross-referenced FR-013 from both; normalized "local work source" to "local work-tracking source" throughout the User Stories, Edge Cases, and the Key Entities heading for terminology consistency with the Requirements section; and trimmed two residual defensive "not an experiment"/"not experimental" phrasings (Assumptions, User Story 3) to plain positive statements, since the non-experimental framing was already established. FR-010/FR-011/FR-012 (single active work-tracking source, single active coding-agent execution integration, tracker-write boundary) and IV-005 (an in-flight attempt stays bound to the tracker/source and execution integration it started with) were re-verified against current Symphony source (`tracker.ex`, `workflow_store.ex`, `config.ex`, `codex/app_server.ex`'s `bind_agent_tools`) and upstream `SPEC.md` §7.4/§14.3, and found already consistent with existing architecture and upstream restart/reload semantics — left unchanged. No genuine unresolved ambiguity remains; no FR/IV/SC numbering changed; no new clarification questions were introduced. The specification is ready for planning.
