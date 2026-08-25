# Feature Specification: Local Work Tracking and Multi-Agent Execution for the Symphony Development Fork

**Feature Branch**: `001-local-tracker-multi-agent` (Spec Kit feature identifier only; per the fork's workflow, no separate git branch is created for this feature — work stays on `development`)

**Created**: 2026-08-25

**Status**: Draft

**Input**: User description: "Evolve Symphony into a narrowly maintained development variant that preserves upstream orchestration semantics while allowing work to come from a lightweight local, repository-owned tracker and allowing execution through more than one supported coding-agent integration. The development variant should retain upstream Symphony's scheduler, reconciliation, retry/backoff behavior, workspace lifecycle, observability, and other core orchestration behavior unless a concrete requirement makes a change necessary. The work-tracking boundary must support a local durable source of work without requiring a hosted issue tracker or hosted control plane. The coding-agent execution boundary must support Claude Code in addition to preserving the existing Codex-oriented behavior, while keeping provider-specific behavior localized rather than turning Symphony itself into a generic agent framework. This scope is coordination and execution of already-defined work. It does not include decomposing statements of work, generating tasks, dependency/DAG planning, knowledge retrieval, or deciding how work enters the tracker. Prefer the smallest behavioral delta from upstream Symphony."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operate Symphony on locally tracked work without a hosted tracker (Priority: P1)

An engineering team maintaining the development fork wants to point Symphony at project work that lives entirely on the local host/repository, so they can pick up, dispatch, and complete Symphony-managed work without provisioning or depending on any hosted issue tracker service or hosted control-plane account.

**Why this priority**: Without this capability, the fork cannot deliver its core premise — teams that don't already run a supported hosted tracker still cannot use Symphony at all. This is the foundational new capability.

**Independent Test**: Configure a Symphony deployment to use only the local work-tracking source (no hosted tracker configured), add one dispatch-eligible work item to it, and observe Symphony poll, dispatch, execute, and carry the item through to a terminal lifecycle state — with no hosted tracker or hosted control-plane service involved at any point.

**Acceptance Scenarios**:

1. **Given** a local work source containing one dispatch-eligible work item, **When** Symphony's poll tick runs, **Then** Symphony creates a workspace and starts a coding-agent run for that item, applying the same dispatch-eligibility rules it applies to a hosted-tracker work item.
2. **Given** a running coding-agent session backed by the local work source, **When** the session completes successfully, **Then** the local work source reflects an updated lifecycle state and Symphony schedules the same continuation/retry check it schedules after any successful run.
3. **Given** no network access to any hosted tracker or hosted control-plane service, **When** Symphony operates entirely against the local work source, **Then** polling, dispatch, retries, and reconciliation continue to function without error.

---

### User Story 2 - Execute work through Claude Code as an alternative coding agent (Priority: P1)

A team wants to run Symphony-managed work using Claude Code as the coding agent for some or all work items, while any existing Codex-based workflow or deployment keeps working exactly as it does today, unmodified.

**Why this priority**: Claude Code support is a required compatibility outcome for the fork. Without it, the fork cannot claim multi-agent execution, which is the second foundational new capability alongside local work tracking.

**Independent Test**: Configure one workflow to execute through Claude Code, dispatch a work item under it, and confirm Symphony carries the run through the same run-attempt lifecycle phases it uses today, ending in a terminal state — while a separate, unmodified Codex-configured workflow continues to run unaffected.

**Acceptance Scenarios**:

1. **Given** a workflow configured to use Claude Code as the coding agent, **When** Symphony dispatches an eligible work item under that workflow, **Then** Symphony launches a Claude Code-backed run inside the work item's assigned per-issue workspace and reports the same class of operator-visible runtime events it reports for a Codex-backed run.
2. **Given** an existing Codex-configured workflow with no configuration changes, **When** Symphony dispatches work under it after Claude Code support is added, **Then** the run behaves exactly as it did before Claude Code support existed.
3. **Given** a Claude Code-backed run that fails or times out, **When** the failure occurs, **Then** Symphony applies the same retry/backoff and reconciliation behavior it applies to an equivalent Codex-backed failure.

---

### User Story 3 - Run a fully self-contained development loop (Priority: P3)

To confirm that local work tracking and multi-agent execution are genuinely independent, composable capabilities rather than a coupled rewrite, a team runs Symphony end-to-end using only the local work source and Claude Code — no hosted tracker and no Codex dependency for that deployment.

**Why this priority**: This is a validating combination of User Story 1 and User Story 2 rather than new orchestration behavior in its own right, so it is valuable but not required to prove either capability individually.

**Independent Test**: Run a Symphony deployment configured with only the local work source and only Claude Code execution; confirm a work item completes its full lifecycle end to end using only those two components.

**Acceptance Scenarios**:

1. **Given** a deployment configured with only the local work source and Claude Code, **When** a work item becomes dispatch-eligible, **Then** Symphony dispatches, executes, and completes the run using only those two components, with no hosted tracker or Codex involvement.
2. **Given** this configuration, **When** its observable orchestration behavior is compared to an equivalent Codex + hosted-tracker deployment, **Then** dispatch order, concurrency limits, retry timing, and reconciliation behavior are the same — only the tracker and agent-execution mechanics differ.

---

### Edge Cases

- What happens when a required dependency for a configured work-tracking source or coding-agent execution integration is missing or invalid at startup or dispatch time (for example, local work-source storage is inaccessible, or a coding-agent executable cannot be found) — does Symphony surface this the same way it surfaces an existing missing/invalid tracker or Codex configuration today?
- What happens if the local work source's storage is deleted, corrupted, or becomes temporarily unreadable between polls?
- How does Symphony behave if a work item's lifecycle state is changed outside of Symphony (for example, a person or another tool directly edits the local work source) while a run for that item is active?
- What happens to in-flight runs and retry timers when the local work source is unavailable during a poll tick, mirroring how Symphony already tolerates a hosted-tracker outage?
- What happens when a workflow does not specify any coding-agent execution integration at all — does the deployment default to the existing Codex-oriented behavior to preserve backward compatibility?
- What happens when a workflow does not specify any work-tracking source at all — does the deployment default to the existing hosted-tracker-oriented behavior to preserve backward compatibility?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST support a work-tracking source that durably persists work items on the local host/repository, usable without any hosted issue tracker service or hosted control-plane account.
- **FR-002**: The local work-tracking source MUST support the same dispatch-eligibility concept Symphony already applies to hosted trackers (state, required-label-equivalent matching, claim status, and concurrency-slot availability).
- **FR-003**: Symphony MUST be able to update a work item's lifecycle state in the local work-tracking source as needed to support dispatch, retry, reconciliation, and completion tracking, mirroring the state-transition support it already provides for hosted trackers.
- **FR-004**: The local work-tracking source MUST remain fully usable when no network connection to any hosted tracker or hosted control-plane service is available. (Network access the coding agent itself uses to reach its model provider is not counted as a control-plane dependency for this requirement.)
- **FR-005**: Symphony MUST support executing coding-agent runs through Claude Code as a coding-agent execution integration, in addition to its existing Codex-oriented execution integration.
- **FR-006**: An existing deployment or workflow configured for Codex execution MUST continue to operate without required configuration changes after Claude Code execution support is added.
- **FR-007**: Provider-specific behavior for each coding-agent execution integration (launch mechanics, protocol handling, provider-specific error mapping) MUST stay localized to that integration and MUST NOT alter shared orchestration behavior for other integrations.
- **FR-008**: When a configured work-tracking source or coding-agent execution integration has a missing or invalid required dependency, Symphony MUST surface a startup or dispatch validation failure using the same operator-visible error-handling pattern it uses today for missing/invalid tracker or Codex configuration, rather than crash or silently skip affected work.
- **FR-009**: A coding-agent execution integration's credentials or tooling MUST NOT be required by, or leak into, another coding-agent execution integration, or into the local work-tracking source's lifecycle-update mechanism.
- **FR-010**: Symphony's behavior when more than one coding-agent execution integration is configured within a single deployment MUST be well-defined. [NEEDS CLARIFICATION: can one Symphony deployment route different work items to different coding-agent execution integrations concurrently (for example, Codex for some items and Claude Code for others, in the same running instance), or does a deployment configure exactly one active coding-agent execution integration at a time?]
- **FR-011**: The write boundary for local work-tracking source lifecycle updates MUST be well-defined relative to Symphony's existing tracker-write boundary (in which ticket mutations are typically performed by the coding agent through host-executed, adapter-owned tool calls rather than directly by the orchestrator). [NEEDS CLARIFICATION: for the local work-tracking source, are lifecycle/state writes performed directly by the Symphony orchestrator process itself, or must they flow through the same agent-invoked, host-executed tool-call pattern used for hosted trackers?]
- **FR-012**: Symphony's behavior when both the local work-tracking source and a hosted tracker are configured within a single deployment MUST be well-defined. [NEEDS CLARIFICATION: can the local work-tracking source and a hosted tracker be configured as simultaneously active work sources within one deployment, or is the local work-tracking source mutually exclusive with hosted trackers per deployment, consistent with today's single active-tracker-per-deployment model?]

### Inherited Invariants (Existing Symphony Behavior That Remains Unchanged)

- **IV-001**: Scheduler dispatch, priority sorting, and concurrency-limit behavior remain unchanged for work sourced from any active work-tracking source, including the local work-tracking source.
- **IV-002**: Reconciliation, stall detection, and retry/backoff timing remain unchanged regardless of which coding-agent execution integration a run uses.
- **IV-003**: Workspace lifecycle, hooks, and workspace-safety invariants (per-issue isolation, root containment, sanitized/collision-resistant workspace keys) remain unchanged regardless of work-tracking source or coding-agent execution integration.
- **IV-004**: Observability and logging conventions (structured logs with issue/session context, existing runtime status/snapshot surfaces) remain unchanged in shape, and are extended to cover the local work-tracking source and any additional coding-agent execution integration.
- **IV-005**: Dynamic workflow-configuration reload semantics remain unchanged: configuration changes are detected and re-applied to future dispatch, retry, and hook execution without requiring a restart.
- **IV-006**: A run-attempt's coding-agent execution stays confined to its assigned per-issue workspace regardless of work-tracking source or coding-agent execution integration in use.

### Key Entities

- **Local Work Source**: A durable, host/repository-local record of work items that Symphony can poll and update using the same normalized work-item model and lifecycle concepts it already uses for hosted trackers, without depending on any hosted tracker service or hosted control-plane account.
- **Coding-Agent Execution Integration**: A pluggable execution boundary through which Symphony launches, monitors, and completes a coding-agent run for a work item. The existing Codex-oriented integration and the new Claude Code integration are each one such integration; each keeps its own provider-specific behavior localized to itself.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A team can stand up a fresh Symphony deployment that sources and completes work entirely from the local work-tracking source, with zero required hosted tracker or hosted control-plane account.
- **SC-002**: A team can configure at least one workflow to execute its coding-agent run through Claude Code and observe that run reach a terminal state (succeeded, failed, or timed out) reported through the same operator-visible lifecycle observability used for Codex runs.
- **SC-003**: An existing Codex-oriented, hosted-tracker-oriented deployment shows no observable change in dispatch, execution, retry, or reconciliation behavior after this capability is added but left unconfigured.
- **SC-004**: Every orchestration invariant inherited from upstream Symphony (scheduler dispatch order, concurrency limits, retry/backoff timing, workspace safety invariants, reconciliation rules) holds identically regardless of which supported work-tracking source or coding-agent execution integration is active.
- **SC-005**: When a configured work-tracking source or coding-agent execution integration has a missing or invalid dependency, an operator can identify the failure from Symphony's existing operator-visible error and observability surface, without inspecting internal state or source code.

## Out of Scope / Non-Goals

- Decomposing statements of work, generating tasks, or otherwise turning prose into schedulable work items.
- Dependency or DAG-based planning or scheduling of any kind.
- Knowledge-base or semantic retrieval features.
- Deciding how work enters the local work-tracking source (authoring, prioritization, or intake workflow) — this feature covers polling and lifecycle updates for already-defined work, not how that work is created.
- A generic, provider-agnostic plugin ecosystem for arbitrary coding agents; this feature adds one additional named coding-agent execution integration (Claude Code) alongside the existing one (Codex), not an open-ended agent framework.
- Changing upstream Symphony's scheduler, reconciliation, retry/backoff, workspace lifecycle, or observability behavior for reasons of architectural cleanliness alone; any change to that inherited behavior must be justified by a concrete requirement in this specification.
- Distributed coordination or hosted orchestration services.
- Subagent policy or model routing within a coding-agent execution integration.

## Assumptions

- The local work-tracking source is scoped to durably storing and updating already-defined work items and their lifecycle state; how work items are authored, decomposed, or prioritized before they enter the tracker is out of scope, per the fork's stated scope boundaries.
- "Local" and "durable" mean the work-tracking source's data survives a Symphony process restart on the same host. Symphony's own in-memory scheduler state (running sessions, retry timers) remains non-durable across restarts exactly as it is upstream; restart recovery continues to work by re-polling the active work-tracking source and reusing preserved workspaces.
- Claude Code execution is expected to satisfy the same class of runtime guarantees the existing Codex execution integration already satisfies (workspace cwd isolation, structured runtime events, a comparable set of retryable failure classes). This feature does not require Claude Code to expose every Codex-specific capability — only the guarantees this specification's inherited invariants depend on.
- The fork's existing repository-owned workflow configuration mechanism remains the way a deployment selects and configures its active work-tracking source and coding-agent execution integration(s); this feature does not introduce a second, competing runtime configuration surface.
- Model-provider network access used by a coding-agent execution integration itself (for example, reaching Claude's or Codex's model backend) is not considered a "hosted control plane" dependency for the purposes of this specification's local/offline requirements.
