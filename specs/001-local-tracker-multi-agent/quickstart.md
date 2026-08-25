# Quickstart: Validating Local Work Tracking and Claude Code Execution

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

These scenarios mirror the spec's own Independent Test for each user story. Each is runnable once the
tasks from `tasks.md` (not yet generated) land; commands assume `elixir/` as the working directory and
follow the existing `AGENTS.md` toolchain (`mise`-managed Elixir 1.19/OTP 28, `mix setup` once).

## Prerequisites

```bash
cd elixir
mix setup
```

A scratch directory to run Symphony against, separate from the repo checkout (workspaces must never be
the source repo — IV-003/IV-006):

```bash
mkdir -p /tmp/symphony-quickstart && cd /tmp/symphony-quickstart
```

## Scenario 1 — Local work-tracking source only (User Story 1, SC-001)

Corresponds to spec's User Story 1 Independent Test: no hosted tracker configured, one dispatch-eligible
item, observe poll → dispatch → execute → terminal state, with no hosted-tracker/control-plane
involvement.

1. Write a minimal `WORKFLOW.md`:

   ```yaml
   ---
   tracker:
     kind: local
   codex:
     command: codex app-server
   ---
   Resolve the assigned work item and report what you changed.
   ```

2. Seed one dispatch-eligible record directly in the local store (or via whatever seeding mechanism
   `tasks.md` implements — e.g. a `mix symphony.local_tracker.add` task, or hand-writing
   `.symphony/local_tracker.json` per contracts/local-tracker-adapter.md's on-disk shape) with
   `state: "todo"` and `dispatchable: true`.
3. Start Symphony against this directory (`bin/symphony` or `mix run --no-halt` per existing
   `README.md` run instructions) with no network access to any hosted tracker/control-plane reachable
   (verifiable by running with e.g. `unshare --net` or simply having no such credentials configured at
   all, since `tracker.kind: local` requires none).
4. **Expected**: a workspace is created for the seeded item, a Codex run starts and completes, and the
   item reaches a terminal lifecycle state in `.symphony/local_tracker.json` if the workflow prompt
   directed a state change (or remains active under existing continuation behavior otherwise — spec
   User Story 1 AS2). No error referencing a hosted tracker or hosted control-plane appears in logs.
5. **Corruption check (FR-013)**: stop Symphony, truncate `.symphony/local_tracker.json` to `""`,
   restart. **Expected**: Symphony surfaces an operator-visible startup/dispatch-validation error
   (`local_tracker_corrupt`) and does NOT silently recreate an empty store.

## Scenario 2 — Claude Code execution only, existing hosted-tracker/Codex config untouched (User Story 2, SC-002/SC-003)

Corresponds to spec's User Story 2 Independent Test, run alongside an unmodified Codex deployment to
confirm SC-003.

1. In a second directory, write:

   ```yaml
   ---
   tracker:
     kind: memory
   agent_execution:
     kind: claude_code
   claude_code:
     command: claude
   ---
   Resolve the assigned work item and report what you changed.
   ```

   (Using `tracker.kind: memory` here isolates this scenario to the coding-agent execution seam only,
   per the spec's independent-test framing — User Story 3 is what composes both new seams.)

2. Configure one dispatch-eligible in-memory issue per existing `Tracker.Memory` test-fixture conventions
   (`test/fixtures/startup_workflow.md` pattern) and start Symphony.
3. **Expected**: Symphony launches a Claude Code-backed run inside the item's per-issue workspace and
   reports the same class of operator-visible runtime events (session started, terminal outcome) it
   reports for a Codex-backed run — visible via the same status dashboard/log conventions
   (`docs/logging.md`), reaching a terminal succeeded state.
4. In parallel (a separate process/directory), run an existing Codex + hosted-tracker
   `WORKFLOW.md` with zero changes. **Expected**: unaffected — identical behavior to before this
   feature existed (SC-003).
5. **Failure/retry check (User Story 2 AS3)**: point `claude_code.command` at a nonexistent executable,
   dispatch a work item. **Expected**: the attempt fails and is retried with the same backoff schedule an
   equivalent Codex launch failure would get (FR-008.2) — not a crash, not a silently skipped item.

## Scenario 3 — Local tracking + Claude Code together (User Story 3, SC-004)

1. Combine both: `tracker.kind: local` and `agent_execution.kind: claude_code` in one `WORKFLOW.md`.
2. Seed one dispatch-eligible local-tracker item; start Symphony with no hosted-tracker/Codex involvement
   at all.
3. **Expected**: the item completes its full lifecycle using only those two components.
4. **Equivalence check (SC-004)**: with equivalent normalized work-item inputs (same priority, labels,
   states) staged both here and in Scenario 1/existing Codex+hosted-tracker deployments, compare dispatch
   order, concurrency-limit enforcement, and retry/backoff decisions — these must match; only
   tracker-specific/coding-agent-specific mechanics and incidental timing may differ.

## Regression gate

Before treating any scenario above as passing, run the existing full gate — this feature must not
regress it:

```bash
make all
```

This is Symphony's existing format-check + `mix specs.check` + `credo --strict` + coverage (100%
threshold) + dialyzer gate (`elixir/AGENTS.md`), applying to both new adapters exactly as it does to every
existing one.
