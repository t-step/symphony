# Quickstart: Validating the Bindle-Backed Tracker Adapter

This is a validation guide, not an implementation checklist — see `tasks.md` for the build steps and
`contracts/bindle-tracker-adapter.md`/`data-model.md` for the exact shapes referenced below.

**Correction pass (2026-08-27)**: the claims-ledger and lifecycle-tool test files this guide previously
referenced no longer exist in this design (see `spec.md`'s Correction Note); this version's test list and
manual proof reflect the corrected projection-enumeration reconciliation and the acquire-success/
spawn-failure compensation path instead.

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
  test/symphony_elixir/bindle_owner_test.exs \
  test/symphony_elixir/bindle_orchestrator_integration_test.exs \
  test/symphony_elixir/tracker_issue_test.exs \
  test/symphony_elixir/tracker_test.exs
```
**Expected**: all pass, using the real temporary SQLite fixture (no installed `bindle` binary required —
the CLI boundary is exercised through the injected `:bindle_cli_module`).

```sh
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/core_test.exs \
  test/symphony_elixir/asana_adapter_test.exs test/symphony_elixir/workspace_and_config_test.exs
```
**Expected**: all pass, unmodified in outcome from before this feature (SC-004) — in particular any test
covering Linear's reassignment-stop and Asana's completed/section-name behavior.

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
   Bindle repo's claim state.
9. (Optional, spawn-failure compensation proof) Configure a way to force
   `Task.Supervisor.start_child/2` to fail for one dispatch attempt (e.g. a worker-host/supervisor
   misconfiguration) after acquisition would otherwise succeed. **Expect**: the orchestrator calls
   `bindle work release <id> --owner <owner>` immediately, before scheduling the ordinary spawn-failure
   retry (SC-006); confirm the retry's own next acquisition attempt succeeds rather than being rejected as
   already-claimed.

Document the actual outcome of this manual proof (pass/fail per expected step, and any deviation) in the
implementation's own completion report — this quickstart does not substitute for that report.
