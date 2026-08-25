# projectmem - symphony

_Last updated: 2026-08-25_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- [DONE] #legacy_678e Legacy issue: Add GitLab Issues tracker adapter -> Add GitLab Issues tracker adapter (fixed)
- [DONE] #legacy_633e Legacy issue: feat(jira): honor blocking issue links (#108) -> feat(jira): honor blocking issue links (#108) (fixed)
- [DONE] #legacy_2121 Legacy issue: Fix Burrito release tag verification -> Fix Burrito release tag verification (fixed)
- [DONE] #legacy_1f32 Legacy issue: Gate Jira new-category issues on blockers -> Gate Jira new-category issues on blockers (fixed)
- [DONE] #legacy_044f Legacy issue: Add GitHub Issues tracker adapter -> Add GitHub Issues tracker adapter (fixed)

## Decisions
- Bootstrap session (2026-08-25): initialized projectmem and Spec Kit (--integration claude) in this existing repo on branch development. DEVELOPMENT_SPEC intentionally left absent -- no spec content was written this session. Next session should begin the Spec Kit lifecycle (/speckit-constitution, /speckit-specify, etc.) to originate specification content, including for the SQLite tracker and Claude Code worker work ported from the Bindle prototype.
- Ratified Symphony Development Fork Constitution v1.0.0 at .specify/memory/constitution.md: 7 principles governing how the fork evolves relative to upstream Symphony (inherit upstream first, minimize fork delta, preserve upstream compatibility, specification before implementation, avoid unnecessary abstraction, preserve execution boundaries, verify fork behavior without regressing upstream). Deliberately excludes concrete implementation choices (tracker, storage, agent runner, packaging) -- those belong to the not-yet-written development specification. DEVELOPMENT_SPEC.md was intentionally not created this session. [.specify/memory/constitution.md]
- Ran /speckit-specify for feature 001-local-tracker-multi-agent: local durable work-tracking source (no hosted tracker/control-plane required) + multi-agent coding-agent execution boundary adding Claude Code alongside existing Codex behavior. Spec expresses new capability as FR-001..FR-012 plus IV-001..IV-006 inherited invariants (scheduler/reconciliation/retry/workspace/observability unchanged), explicit non-goals (no task decomposition, no DAG/dependency planning, no generic plugin framework, no Bindle), and 3 deliberate [NEEDS CLARIFICATION] markers deferred to a future /speckit-clarify pass: (1) can one deployment route work to >1 coding-agent execution integration concurrently, (2) does the orchestrator write local-tracker lifecycle state directly or via the existing agent-invoked tool-call pattern, (3) can the local tracker and a hosted tracker be simultaneously active in one deployment. DEVELOPMENT_SPEC.md remains absent; SPEC.md untouched; committed as 644a7ce on development and pushed to origin/development. No later Spec Kit lifecycle stage was run. [specs/001-local-tracker-multi-agent/spec.md]
- Revised specs/001-local-tracker-multi-agent/spec.md per human review: reframed feature as maintained fork behavior (not experiment/spike); resolved FR-010 (exactly one active coding-agent execution integration per deployment, no per-item runtime routing, multi-instance composition instead), FR-011 (local tracker writes flow through existing agent-invoked/host-executed tracker-write boundary, not new orchestrator APIs), FR-012 (exactly one active work-tracking source per deployment) -- removing all 3 NEEDS CLARIFICATION markers; corrected FR-002/FR-003 to keep claim/retry/concurrency/priority/scheduler-eligibility as orchestration-owned; rewrote User Story 3 as normal supported composition; strengthened SC-002 to require an actually-demonstrated successful Claude Code run; revised IV-004 for cross-integration observability without mandating identical telemetry shape; tightened FR-008 startup-vs-runtime failure handling; added FR-013 local-tracker-corruption-must-surface-visibly requirement; updated requirements checklist to reflect all clarifications resolved. No Symphony application source was touched. [specs/001-local-tracker-multi-agent/spec.md]
- Applied a second narrow human-review cleanup pass to specs/001-local-tracker-multi-agent/spec.md and its requirements checklist: FR-003 now scopes local lifecycle-state mutations to workflow/business progression via agent-invoked, host-executed tracker tooling, explicitly excluding claim/retry/reconciliation/concurrency from requiring a lifecycle mutation; User Story 1 AS2 no longer requires every successful coding-agent session to mutate lifecycle state (mutation only when workflow-directed, otherwise existing active-item continuation applies); the two remaining unanswered edge-case questions (no coding-agent integration selected -> default to Codex; no work-tracking source configured -> configuration invalid, not a hosted-tracker default) were converted to explicit resolved behavior; IV-005 now defines that an in-flight run attempt stays bound to the tracker/source and execution integration it started with, with config changes applying to future run attempts only; title changed to '...for the Symphony Fork' (drop 'Development'); User Story 3 renamed to 'Operate Symphony with Local Work Tracking and Claude Code'; Assumptions' first bullet tightened to drop the feasibility-contingency clause; User Story 2 reworded to avoid implying multiple workflows per deployment, preferring 'a deployment, configured through its WORKFLOW.md'; checklist title updated to match, no longer says 'Multi-Agent Execution'. No Symphony application source touched; no later Spec Kit lifecycle stage run; not committed. [specs/001-local-tracker-multi-agent/spec.md]
- Final pre-planning spec cleanup for 001-local-tracker-multi-agent: tightened FR-013 to distinguish permitted fresh local-tracker initialization from prohibited silent recreation of established local durable state that goes missing/corrupt/unreadable (attributed as a source-level operator-visible failure, not an item-level attempt failure); reworded 2 Edge Cases bullets to resolve the transient-vs-established-loss ambiguity and cross-reference FR-013; normalized 'local work source' -> 'local work-tracking source' terminology throughout; trimmed 2 residual defensive not-experimental phrasings. IV-005, FR-010/011/012, restart-recovery assumptions, and default-Codex/missing-tracker-invalid behavior were re-verified against current source (tracker.ex, workflow_store.ex, config.ex, codex/app_server.ex bind_agent_tools) and upstream SPEC.md and left unchanged as already correct/minimal. No implementation source touched; no later Spec Kit stage run; not committed. [specs/001-local-tracker-multi-agent/spec.md]

## Notes
- Add generic tracker interface with Linear adapter (#102)
- Add Jira Cloud tracker adapter
- Add Asana tracker adapter
- Make terminal workspace cleanup safe
- Keep retry dispatch fresh without leaking claims
- Retry failed workspace setup and anchor local roots
- Block generic tool input and document idle timeouts
- Bump Symphony version to 0.0.2
- Add Symphony release skill
- Scrub GitHub and GitLab authentication token aliases (#119)

## Key files
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/workflow_store.ex`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/lib/symphony_elixir.ex`
- `elixir/lib/symphony_elixir/agent_runtime_supervisor.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/test/symphony_elixir/live_e2e_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/config/config.exs`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/test/fixtures/startup_workflow.md`
- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/AGENTS.md`
- `.github/workflows/burrito-release.yml`
- `elixir/.gitignore`
- `elixir/README.md`
- `elixir/lib/symphony_elixir/cli.ex`
- `elixir/mix.exs`
- `elixir/mix.lock`

## Open questions
- None logged yet.
