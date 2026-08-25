# Feature Specification: Local Work Tracking and Selectable Coding-Agent Execution for the Symphony Fork

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
2. **Given** a running coding-agent session backed by the local work source, **When** the session completes successfully, **Then** Symphony schedules the same continuation/retry check it schedules after any successful run; if the workflow directs a lifecycle-state mutation for that outcome, the local work source reflects it, and otherwise the work item remains active under Symphony's existing active-item continuation behavior, unchanged.
3. **Given** no network access to any hosted tracker or hosted control-plane service, **When** Symphony operates entirely against the local work source, **Then** polling, dispatch, retries, and reconciliation continue to function without error.

---

### User Story 2 - Execute work through Claude Code as an alternative coding agent (Priority: P1)

A team wants to run Symphony-managed work using Claude Code as the coding-agent execution integration for a deployment, configured through its WORKFLOW.md, while any existing Codex-configured deployment keeps working exactly as it does today, unmodified.

**Why this priority**: Claude Code support is a required compatibility outcome for the fork. Without it, the fork cannot offer selectable coding-agent execution, which is the second foundational capability alongside local work tracking.

**Independent Test**: Configure a Symphony deployment's workflow to execute through Claude Code, dispatch a work item under it, and confirm Symphony carries the run through the same run-attempt lifecycle phases it uses today, ending in a terminal state — while a separate, unmodified Codex-configured deployment continues to run unaffected on its own workflow configuration.

**Acceptance Scenarios**:

1. **Given** a deployment, configured through its WORKFLOW.md, to use Claude Code as the coding-agent execution integration, **When** Symphony dispatches an eligible work item under that deployment, **Then** Symphony launches a Claude Code-backed run inside the work item's assigned per-issue workspace and reports the same class of operator-visible runtime events it reports for a Codex-backed run.
2. **Given** a separate, existing Codex-configured deployment with no configuration changes, **When** Symphony dispatches work under it after Claude Code support is added, **Then** the run behaves exactly as it did before Claude Code support existed.
3. **Given** a Claude Code-backed run that fails or times out, **When** the failure occurs, **Then** Symphony applies the same retry/backoff and reconciliation behavior it applies to an equivalent Codex-backed failure.

---

### User Story 3 - Operate Symphony with Local Work Tracking and Claude Code (Priority: P3)

A team runs Symphony end-to-end using only the local work-tracking source and Claude Code as its coding-agent execution integration — no hosted tracker and no Codex dependency for that deployment. This is a normal supported operating configuration: the local work-tracking source and the Claude Code execution integration are each independently supported capabilities, and running them together is ordinary composition of two supported capabilities, not a special or experimental combination.

**Why this priority**: This configuration composes two independently required capabilities (User Story 1 and User Story 2) rather than introducing new orchestration behavior of its own, so it is a supported deployment shape but not required to deliver either capability individually.

**Independent Test**: Run a Symphony deployment configured with only the local work source and only Claude Code execution; confirm a work item completes its full lifecycle end to end using only those two components.

**Acceptance Scenarios**:

1. **Given** a deployment configured with only the local work source and Claude Code, **When** a work item becomes dispatch-eligible, **Then** Symphony dispatches, executes, and completes the run using only those two components, with no hosted tracker or Codex involvement.
2. **Given** this configuration, **When** its orchestration decisions are compared to an equivalent Codex + hosted-tracker deployment given equivalent normalized work-item inputs, **Then** scheduler dispatch order, concurrency-limit enforcement, retry/backoff decisions, and reconciliation decisions are the same — only tracker-specific and coding-agent-specific mechanics and incidental timing differ.

---

### Edge Cases

- What happens when a required dependency for a configured work-tracking source or coding-agent execution integration is missing or invalid — either detectable at startup, or only encountered at dispatch/runtime (for example, local work-source storage is inaccessible, or a coding-agent executable cannot be found)? Does Symphony validate what it can eagerly at startup using the same operator-visible error-handling pattern it uses today for missing/invalid tracker or Codex configuration, and route anything only detectable later into its normal attempt failure/retry/observability path?
- What happens if the local work source's storage is deleted, corrupted, or becomes temporarily unreadable between polls? A transient/temporary read failure should be tolerated the way Symphony already tolerates a hosted-tracker outage; corrupt or unreadable durable state must surface as an operator-visible failure rather than being silently recreated, truncated, or reset.
- How does Symphony behave if a work item's lifecycle state is changed outside of Symphony (for example, a person or another tool directly edits the local work source) while a run for that item is active?
- What happens to in-flight runs and retry timers when the local work source is unavailable during a poll tick, mirroring how Symphony already tolerates a hosted-tracker outage?
- If a workflow does not select any coding-agent execution integration, Symphony defaults that deployment to its existing Codex-oriented execution behavior, preserving backward compatibility with today's unconfigured-integration behavior.
- If a workflow does not configure any work-tracking source, Symphony treats that configuration as invalid — consistent with Symphony's current behavior of requiring a configured tracker — rather than defaulting to a hosted tracker or the local work-tracking source.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Symphony MUST support a work-tracking source that durably persists work items on the local host/repository, usable without any hosted issue tracker service or hosted control-plane account.
- **FR-002**: The local work-tracking source MUST supply the normalized work-item information (state, required-label-equivalent metadata, and any other fields) that Symphony's existing orchestrator needs to apply its own dispatch-eligibility rules. Claim state, retry state, concurrency-slot availability, priority handling, and scheduler-eligibility determination remain Symphony orchestration concerns and are not the local work-tracking source's responsibility.
- **FR-003**: The local work-tracking source MUST support workflow/business lifecycle-state progression (for example, marking a work item in-progress, completed, or blocked, as directed by the workflow) through the same agent-invoked, host-executed tracker-write boundary Symphony already uses for hosted trackers. This requirement covers workflow/business lifecycle progression only: claiming, retry scheduling, reconciliation, concurrency-slot management, and other scheduler state remain orchestration concerns and do not require a local work-item lifecycle-state mutation to function. The concrete mechanism implementing local lifecycle writes is left unspecified here and belongs to the planning stage.
- **FR-004**: The local work-tracking source MUST remain fully usable when no network connection to any hosted tracker or hosted control-plane service is available. (Network access the coding agent itself uses to reach its model provider is not counted as a control-plane dependency for this requirement.)
- **FR-005**: Symphony MUST support executing coding-agent runs through Claude Code as a coding-agent execution integration, in addition to its existing Codex-oriented execution integration.
- **FR-006**: An existing deployment or workflow configured for Codex execution MUST continue to operate without required configuration changes after Claude Code execution support is added.
- **FR-007**: Provider-specific behavior for each coding-agent execution integration (launch mechanics, protocol handling, provider-specific error mapping) MUST stay localized to that integration and MUST NOT alter shared orchestration behavior for other integrations.
- **FR-008**: Symphony MUST validate a configured work-tracking source's and coding-agent execution integration's required dependencies as early as practical, surfacing a startup validation failure — using the same operator-visible error-handling pattern it uses today for missing/invalid tracker or Codex configuration — for anything detectable at startup. A missing or invalid dependency detectable only at dispatch or runtime MUST enter Symphony's normal attempt failure/retry/observability path rather than crashing the process or silently skipping the affected work.
- **FR-009**: A coding-agent execution integration's credentials or tooling MUST NOT be required by, or leak into, another coding-agent execution integration, or into the local work-tracking source's lifecycle-update mechanism.
- **FR-010**: A single Symphony deployment MUST have exactly one active coding-agent execution integration at a time — Codex or Claude Code, not both. Symphony MUST NOT route different work items within one deployment to different coding-agent execution integrations at runtime, and MUST NOT execute Codex and Claude Code concurrently within a single deployment. A team needing both execution integrations in use at once achieves that by running multiple Symphony deployments, each with its own single active coding-agent execution integration, not by adding per-work-item runtime routing to one instance.
- **FR-011**: Local work-tracking source lifecycle mutations MUST be performed through Symphony's existing tracker-write boundary: workflow/business lifecycle mutations are carried out by agent-invoked, host-executed tracker tooling, rather than by adding tracker-specific lifecycle-write APIs to the orchestrator itself. The specific mechanism implementing that tooling for the local work-tracking source is left unspecified here and belongs to the planning stage.
- **FR-012**: A single Symphony deployment MUST have exactly one active work-tracking source at a time — either the local work-tracking source or one configured hosted tracker, never more than one simultaneously. This preserves Symphony's existing single-active-tracker-per-deployment model; the local work-tracking source and a hosted tracker are not simultaneously active within one deployment.
- **FR-013**: If the local work-tracking source's durable state is corrupt or otherwise unreadable, Symphony MUST surface an operator-visible failure rather than silently recreating, truncating, or resetting that state.

### Inherited Invariants (Existing Symphony Behavior That Remains Unchanged)

- **IV-001**: Scheduler dispatch, priority sorting, and concurrency-limit behavior remain unchanged for work sourced from any active work-tracking source, including the local work-tracking source.
- **IV-002**: Reconciliation, stall detection, and retry/backoff timing remain unchanged regardless of which coding-agent execution integration a run uses.
- **IV-003**: Workspace lifecycle, hooks, and workspace-safety invariants (per-issue isolation, root containment, sanitized/collision-resistant workspace keys) remain unchanged regardless of work-tracking source or coding-agent execution integration.
- **IV-004**: Existing Codex-oriented observability and logging conventions (structured logs with issue/session context, existing runtime status/snapshot surfaces) remain backward compatible and unchanged in shape. Common lifecycle and session observability — that a run started, which coding-agent execution integration it used, its terminal outcome, and its retry/reconciliation events — is available across every supported coding-agent execution integration, without requiring every integration to expose a literally identical telemetry/event shape for provider-specific detail.
- **IV-005**: Dynamic workflow-configuration reload semantics remain unchanged: configuration changes — including a change to the selected work-tracking source or coding-agent execution integration — are detected and applied to future dispatch, retry, and hook execution without requiring a restart. A run attempt already in flight when such a configuration change is detected remains bound to the work-tracking source and coding-agent execution integration it started with for the remainder of that attempt; the new configuration takes effect starting with the deployment's next run attempt.
- **IV-006**: A run-attempt's coding-agent execution stays confined to its assigned per-issue workspace regardless of work-tracking source or coding-agent execution integration in use.

### Key Entities

- **Local Work Source**: A durable, host/repository-local record of work items that Symphony can poll and update using the same normalized work-item model and lifecycle concepts it already uses for hosted trackers, without depending on any hosted tracker service or hosted control-plane account. Exactly one work-tracking source — this local source, or one hosted tracker — is active within a given Symphony deployment at a time.
- **Coding-Agent Execution Integration**: A pluggable execution boundary through which Symphony launches, monitors, and completes a coding-agent run for a work item. The existing Codex-oriented integration and the new Claude Code integration are each one such integration; each keeps its own provider-specific behavior localized to itself. Exactly one coding-agent execution integration is active within a given Symphony deployment at a time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A team can stand up a fresh Symphony deployment that sources and completes work entirely from the local work-tracking source, with zero required hosted tracker or hosted control-plane account.
- **SC-002**: A team can configure a workflow to execute its coding-agent run through Claude Code, and at least one such run is demonstrated to actually complete successfully end to end, reaching a terminal succeeded state reported through the same operator-visible lifecycle observability used for Codex runs. Failure and timeout handling for Claude Code-backed runs may be demonstrated separately from this successful-run requirement.
- **SC-003**: An existing Codex-oriented, hosted-tracker-oriented deployment shows no observable change in dispatch, execution, retry, or reconciliation behavior after this capability is added but left unconfigured.
- **SC-004**: Every orchestration invariant inherited from upstream Symphony — scheduler dispatch order, concurrency-limit enforcement, retry/backoff decisions, workspace safety invariants, and reconciliation rules — produces the same decisions given equivalent normalized inputs, regardless of which supported work-tracking source or coding-agent execution integration is active. Provider-specific mechanics and incidental timing are not required to be identical.
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

- This capability set is intended as ongoing, maintained behavior for the Symphony fork — not a spike, feasibility trial, or temporary exercise.
- The local work-tracking source is scoped to durably storing and updating already-defined work items and their lifecycle state; how work items are authored, decomposed, or prioritized before they enter the tracker is out of scope, per the fork's stated scope boundaries.
- "Local" and "durable" mean the work-tracking source's data survives a Symphony process restart on the same host. Symphony's own in-memory scheduler state (running sessions, retry timers) remains non-durable across restarts exactly as it is upstream; restart recovery continues to work by re-polling the active work-tracking source and reusing preserved workspaces.
- Claude Code execution is expected to satisfy the same class of runtime guarantees the existing Codex execution integration already satisfies (workspace cwd isolation, structured runtime events, a comparable set of retryable failure classes). This feature does not require Claude Code to expose every Codex-specific capability — only the guarantees this specification's inherited invariants depend on.
- The fork's existing repository-owned workflow configuration file (`WORKFLOW.md`) remains the single runtime configuration surface through which a deployment selects and configures its one active work-tracking source and its one active coding-agent execution integration; this feature does not introduce a second, competing runtime configuration surface.
- Model-provider network access used by a coding-agent execution integration itself (for example, reaching Claude's or Codex's model backend) is not considered a "hosted control plane" dependency for the purposes of this specification's local/offline requirements.
