# Quickstart: Validating the Bindle-Backed Tracker Adapter

This is a validation guide, not an implementation checklist — see `tasks.md` for the build steps and
`contracts/bindle-tracker-adapter.md`/`data-model.md` for the exact shapes referenced below.

**Correction pass (2026-08-27)**: the claims-ledger and lifecycle-tool test files this guide previously
referenced no longer exist in this design (see `spec.md`'s Correction Note); this version's test list and
manual proof reflect the corrected projection-enumeration reconciliation and the acquire-success/
spawn-failure compensation path instead.

**Second correction pass (2026-08-27, same day)**: the agent-invoked task-completion tool is restored
(narrowly — spec.md FR-025–FR-027), the acquisition call site and re-validation now branch on fresh-admission
vs. continuation-retry (FR-016/FR-024), the continuation field is `continuation_allowed` (not
`routed_by_assignment`, now covering Asana too), and startup reconciliation's per-id retry is bounded rather
than restart-only. This version's test list and manual proof are updated accordingly — see `spec.md`'s
second Correction Note.

## Prerequisites

- A Bindle repository (`~/Developer/bindle` or any other Bindle-managed repo) with the `bindle` CLI
  installed and on `$PATH` (`bindle --version` succeeds).
- At least one `type = 'task'` work item in that repository, and a published projection
  (`bindle work publish` succeeds and reports a path ending in `symphony-projection.sqlite3`).
- A Symphony deployment configured with:
  ```toml
  [tracker]
  kind = "bindle"

  [tracker.provider]
  # repo_path defaults to Config.workflow_dir() (research.md R15) — override only if the Bindle
  # repository differs from the repo containing this deployment's WORKFLOW.md:
  # repo_path = "/absolute/path/to/the/bindle-managed-repo"
  # path and bindle_bin take their documented defaults; owner_id_path is Symphony-owned state,
  # independent of repo_path.
  ```

## Unit/integration test validation (run before any live run)

```sh
cd elixir
mise exec -- mix test test/symphony_elixir/bindle_adapter_test.exs \
  test/symphony_elixir/bindle_projection_test.exs \
  test/symphony_elixir/bindle_cli_test.exs \
  test/symphony_elixir/bindle_agent_tool_test.exs \
  test/symphony_elixir/bindle_owner_test.exs \
  test/symphony_elixir/bindle_orchestrator_integration_test.exs \
  test/symphony_elixir/tracker_issue_test.exs \
  test/symphony_elixir/tracker_test.exs
```
**Expected**: all pass, using the real temporary SQLite fixture (no installed `bindle` binary required —
the CLI boundary is exercised through the injected `:bindle_cli_module`). `bindle_agent_tool_test.exs`
confirms the task-completion tool resolves its target only from session-bound state (never a supplied
argument), calls `done` then `publish`, and does not retry `done` when only `publish` fails.
`bindle_orchestrator_integration_test.exs` additionally confirms `acquire_issue/2` is called only in
fresh-admission mode and is never called again for a continuation retry of an issue already in
`state.claimed`.

```sh
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs \
  test/symphony_elixir/asana_adapter_test.exs test/symphony_elixir/workspace_and_config_test.exs
```
**Expected**: all pass, unmodified in outcome from before this feature (SC-004) — in particular any test
covering Linear's reassignment-stop, and `asana_adapter_test.exs`'s new coverage of `continuation_allowed`
being populated from `task["completed"]` independent of section/state (SC-010).

```sh
mise exec -- mix test
```
**Expected**: full suite passes except the two pre-existing, already-logged flaky wall-clock-margin tests
(`orchestrator_status_test.exs:905` "restarts stalled workers", `core_test.exs:1164` "abnormal worker exit
increments retry attempt progressively" — projectmem issues #0002/#0005), which are unrelated to this
feature and may intermittently fail under full-suite scheduler contention regardless of these changes.

## Manual end-to-end proof (if a real Bindle repo is available)

1. In the Bindle repo: create one `type = 'task'` work item (via Bindle's own tooling — out of scope here
   to specify how) and confirm it is `dispatchable` in the ledger.
2. `bindle work publish` — confirm the projection file is written/refreshed.
3. Start Symphony with `tracker.kind: bindle` pointed at that repo.
4. **Expect**: within one poll cycle, Symphony's orchestrator logs dispatching the task; `bindle work
   claim <id> --owner <owner>` is invoked with no `--worktree`/`--branch` argument (observable via the
   Bindle repo's own claim state — the task now shows as claimed by Symphony's persisted owner id, with no
   `worktree_path` recorded).
5. `bindle work publish` again — the task's projection row now reads `dispatchable: 0` (claimed).
6. **Expect**: Symphony's running agent for that task is NOT terminated on the next poll (SC-003) — this
   is the core regression this feature exists to prevent; confirm via Symphony's own logs/status that the
   worker is still `running`, not `terminated`/`released`.
7. Let the agent run reach a terminal state (or manually end it for the proof). **Expect**: the
   orchestrator's existing terminal-state reconciliation fires, `bindle work release <id> --owner <owner>`
   is invoked, and the Bindle-side claim is released — confirm via the Bindle repo's own claim state
   showing no active claim for that task afterward.
8. (Optional, crash-recovery proof) Kill the Symphony process between step 4 and step 6, leaving a
   dangling Bindle claim; restart Symphony against the same repo/config. **Expect**: before normal polling
   resumes, startup-time reconciliation reads the current projection, enumerates every task id it lists,
   and issues an owner-scoped release for each — including the dangling one, which now releases (SC-007) —
   with no local record of which task Symphony previously claimed driving that recovery; confirm via the
   Bindle repo's claim state. If a release call is made to fail transiently during this sweep (e.g. by
   briefly making the `bindle` binary unavailable), confirm a bounded number of follow-up retries occur
   using the existing retry timer before normal polling is affected, and that if the failure persists past
   the retry budget, a persistent, operator-visible failure naming the task id is logged rather than the
   claim being silently declared recovered (FR-029).
9. (Optional, spawn-failure compensation proof) Configure a way to force
   `Task.Supervisor.start_child/2` to fail for one dispatch attempt (e.g. a worker-host/supervisor
   misconfiguration) after acquisition would otherwise succeed. **Expect**: the orchestrator calls
   `bindle work release <id> --owner <owner>` immediately, before scheduling the ordinary spawn-failure
   retry (SC-006); confirm the retry's own next acquisition attempt succeeds rather than being rejected as
   already-claimed (this retry is a fresh-admission retry, since the compensating release cleared
   `state.claimed`).
10. (Continuation-retry proof, FR-016/FR-024/SC-008) With the task from step 4 still claimed and running,
    kill only the worker process (not the whole Symphony process) so the orchestrator schedules an ordinary
    crash-mid-run retry. **Expect**: the retry does NOT call `bindle work claim` again for this task (observe
    no second claim attempt in Symphony's logs, and no `already_claimed` rejection) — it proceeds straight
    to respawning the worker, reusing the existing Bindle claim and workspace/branch; confirm the task's
    Bindle claim state is unchanged throughout (still held by the same owner, `claimed_at` unchanged).
11. (Agent-triggered task completion + projection-refresh proof, FR-025–FR-027/SC-009) While the task from
    step 4 is running, have the coding-agent session invoke the task-completion tool. **Expect**: Symphony
    invokes `bindle work done <id>` for exactly that session's bound task (confirm via the Bindle repo's own
    ledger that the task's `status` is now `done`), immediately followed by `bindle work publish` — confirm
    the published projection's row for that task now reads `status: "done"` **without** a separate, manual
    `bindle work publish` step by the operator. If `publish` is made to fail (e.g. by making the `bindle`
    binary briefly unavailable immediately after `done` succeeds), confirm the tool's result reports the
    `done` transition as successful with the `publish` failure surfaced distinctly, and confirm no second
    `bindle work done` call is made.

Document the actual outcome of this manual proof (pass/fail per expected step, and any deviation) in the
implementation's own completion report — this quickstart does not substitute for that report.
