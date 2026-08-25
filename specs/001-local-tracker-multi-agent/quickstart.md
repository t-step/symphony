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

2. **Fresh-initialization check (FR-013, research.md R2/R2a)**: before starting Symphony, confirm neither
   `.symphony/local_tracker.json` nor `.symphony/local_tracker.json.established` exists, then attempt to
   start Symphony anyway. **Expected**: Symphony refuses to start the scheduling loop —
   `local_tracker_not_initialized`, an operator-visible startup failure naming the remediation (run
   `symphony local-tracker init`). This is the same failure *class* a missing hosted-tracker credential
   already produces, just a different specific reason.
3. Run `symphony local-tracker init` (or `symphony local-tracker init WORKFLOW.md` if not run from this
   directory). **Expected**: both files are created; the data file contains
   `{"format_version": 1, "issues": {}}`; the command exits `0` without starting the orchestrator.
   Re-run the exact same command again. **Expected**: refuses (already established), makes no changes —
   confirms `init` is not accidentally destructive on repeat invocation.
4. Seed one dispatch-eligible record in the now-initialized store (hand-editing
   `.symphony/local_tracker.json` per contracts/local-tracker-adapter.md's on-disk shape, or via whatever
   seeding mechanism `tasks.md` implements) with `state: "todo"` and `dispatchable: true`.
5. Start Symphony against this directory (`bin/symphony` or `mix run --no-halt` per existing
   `README.md` run instructions) with no network access to any hosted tracker/control-plane reachable
   (verifiable by running with e.g. `unshare --net` or simply having no such credentials configured at
   all, since `tracker.kind: local` requires none).
6. **Expected**: a workspace is created for the seeded item, a Codex run starts and completes, and the
   item reaches a terminal lifecycle state in `.symphony/local_tracker.json` if the workflow prompt
   directed a state change (or remains active under existing continuation behavior otherwise — spec
   User Story 1 AS2). No error referencing a hosted tracker or hosted control-plane appears in logs.
7. **Normal restart with established tracker intact**: stop Symphony, restart it against the same,
   untouched directory. **Expected**: starts cleanly, no re-initialization prompt, item state as left by
   step 6 is exactly preserved.
8. **Corruption check (FR-013, established store)**: stop Symphony, truncate `.symphony/local_tracker.json`
   to `""` (leave `.symphony/local_tracker.json.established` in place), restart. **Expected**: Symphony
   surfaces an operator-visible startup/dispatch-validation error (`local_tracker_corrupt`) and does NOT
   silently recreate an empty store.
9. **Established-state-loss while stopped (FR-013)**: restore a valid `.symphony/local_tracker.json`
   (undoing step 8), then **delete** `.symphony/local_tracker.json.established` while Symphony is stopped,
   and restart. **Expected**: `local_tracker_ambiguous_state` (`:marker_missing`) — an operator-visible
   startup failure, NOT silent establishment and NOT treated as fresh/never-initialized. Confirm the data
   file is untouched (still contains the item from step 4/6). Resolve it by re-running
   `symphony local-tracker init` — **expected**: completes by writing only the marker, the data file's
   content is byte-for-byte unchanged, and Symphony now starts normally.
10. **Established-state-loss while running (FR-013/FR-008.4)**: with Symphony running normally against the
    established store, delete `.symphony/local_tracker.json` (the data file only) out-of-band while
    Symphony keeps running. **Expected**: the next poll tick's `fetch_issues_by_states/ids` call fails
    with `local_tracker_corrupt` (`:missing_after_established`); Symphony skips that dispatch tick, leaves
    any already-running attempt undisturbed, logs an operator-visible failure repeatedly on subsequent
    ticks, and does NOT crash or silently recreate an empty store (FR-008.4).
11. **Deliberate reset**: with Symphony stopped, run `symphony local-tracker init --reset`. **Expected**:
    both files are deleted and recreated fresh (`{"issues": {}}`), unlike step 9's non-destructive
    re-run — confirming `--reset` is the only path that discards existing data, and it is always explicit.
12. **`tracker.provider.path` restart-only check (research.md R9a)**: re-seed one item, start Symphony,
    then edit `WORKFLOW.md` to point `tracker.provider.path` at a different, uninitialized path while
    leaving `tracker.kind: local` unchanged. **Expected**: within one `WorkflowStore` reload tick,
    Symphony's effective config still reflects the *original* path (no behavior change) — confirm via
    logs/dashboard that the original item is still tracked and no "issue no longer visible" reconciliation
    event fires for it. Restart Symphony. **Expected**: only now does Symphony pick up the new path, and
    since it was never initialized, Symphony refuses to start per step 2 above (not silently reset).
13. **Concurrent lifecycle mutation safety (research.md R1a)**: seed two dispatch-eligible items with
    `agent.max_concurrent_agents` ≥ 2 configured, start Symphony, and let both dispatch concurrently so
    each item's coding-agent session calls `local_tracker_set_state` at roughly the same time. **Expected**:
    both mutations land — inspect `.symphony/local_tracker.json` afterward and confirm both items reflect
    their own new state, with neither write having been silently discarded by the other (no lost update).

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
6. **MCP lifecycle tool call reaches the correct bound issue (research.md R6a)**: configure `tracker.kind:
   local` instead of `memory` for this step (combining with Scenario 1's setup), seed one dispatch-eligible
   item, and give the workflow prompt an explicit instruction to call the lifecycle tool (e.g. "mark this
   item in_progress, then done"). **Expected**: the tool call succeeds and
   `.symphony/local_tracker.json` reflects the mutation against *that exact item's* record — confirm by
   inspecting the file directly, not just the run's reported success.
7. **Two concurrent Claude-backed work items cannot cross-call each other's tracker context (research.md
   R6a)**: with `agent.max_concurrent_agents` ≥ 2, seed two dispatch-eligible items (still `tracker.kind:
   local`) with workflow prompts instructing each to mark *itself* (not a specified ID — the workflow
   prompt should not name an item ID) `in_progress`. **Expected**: after both runs complete, each item's
   own record reflects its own mutation and neither item shows the other's identifier/content — confirming
   each run's MCP listener only ever had its own issue in scope. (Optional deeper check, implementation
   permitting: capture both runs' ephemeral MCP ports/tokens from logs and manually attempt an HTTP request
   to run A's port using run B's token, or vice versa — **expected**: rejected, not merely "would have
   happened to hit the right issue anyway.")
8. **Remote-worker rejection (research.md R6a)**: configure `worker.ssh_hosts` with any non-empty value
   alongside `agent_execution.kind: claude_code` in the same `WORKFLOW.md`, and attempt to start Symphony.
   **Expected**: Symphony refuses to start — an operator-visible config validation failure naming the
   incompatibility (Claude Code execution does not support remote worker hosts) — not a silent fallback to
   local execution, and not a confusing failure deep inside a launched turn. Removing either
   `worker.ssh_hosts` or switching back to `agent_execution.kind: codex` allows normal startup again;
   confirm `worker.ssh_hosts` alone, with `agent_execution.kind: codex` (the default), still dispatches to
   the remote host exactly as it did before this feature existed (no regression to existing Codex
   remote-worker behavior).

## Scenario 3 — Local tracking + Claude Code together (User Story 3, SC-004)

1. Combine both: `tracker.kind: local` and `agent_execution.kind: claude_code` in one `WORKFLOW.md`. Run
   `symphony local-tracker init` first (Scenario 1 step 3) — required before Symphony will start against
   this `tracker.kind: local` deployment, same as every other local-tracker deployment.
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
