# Contract: `SymphonyElixir.Bindle.Adapter`

This contract fixes the shape of the new adapter and the two new `Tracker` behaviour callbacks. It does
not restate `002-bindle-integration`'s architectural contract (frozen, authoritative) — it makes that
contract's abstract requirements concrete against this repository's actual current code.

**Correction pass (2026-08-27)**: this contract no longer includes a `done`/completion wrapper or an
agent-invoked lifecycle tool (§5 removed entirely — see spec.md User Story 5/FR-018/FR-019); `claim`'s
signature no longer accepts `--worktree`/`--branch` (research.md R6); `release_issue/2` is id-based, not
`Issue.t()`-based (research.md R13); and two new contracts are added — acquire-success/spawn-failure
compensation (§3) and startup reconciliation (§7). See `research.md` R4–R7, R12–R15 for the full grounding
behind each change.

**Second correction pass (2026-08-27, same day)**: after `002-bindle-integration` FR-013's correction (task
`done` vs. milestone `accepted`) and further Symphony-runtime grounding, this contract restores a narrow
agent-invoked task-completion tool (new §9, research.md R17), adds `done`/`publish` to the CLI wrapper (§4,
research.md R18) — used only by §9, never by the acquire/release seam — corrects §2's acquisition call site
to fire only in fresh-admission mode (research.md R16), and adds bounded per-id retry to §7's startup
reconciliation (research.md R19). None of these reopen `002-bindle-integration`; each makes this feature
conform to its FR-013 correction and to newly-verified runtime facts more closely, not less.

## 1. `Tracker` behaviour addition

```elixir
@callback acquire_issue(Issue.t(), keyword()) :: :ok | {:error, term()}
@callback release_issue(issue_id :: String.t(), keyword()) :: :ok | {:error, term()}

@optional_callbacks acquire_issue: 2, release_issue: 2
```

`Tracker.acquire_issue/2` and `Tracker.release_issue/2` (new public functions on `SymphonyElixir.Tracker`
itself, mirroring the existing `Tracker.fetch_issues_by_states/1` delegation pattern) resolve the active
adapter and call through only if it exports the callback (`Code.ensure_loaded?/1` +
`function_exported?/3`, the same pattern `Tracker.validate_config/1` already uses); otherwise they return
`:ok` unconditionally — a complete no-op.

`release_issue/2` takes the issue's stable id, not a full `Issue.t()` (data-model.md §8): at least one
genuine orchestrator release call site has only an id available, and this feature does not fabricate a
partial `Issue` to force callback symmetry. `acquire_issue/2` keeps the full `Issue.t()`, since it is
always genuinely available at its one call site.

## 2. Orchestrator call sites (single call site per release event)

- **Acquire — fresh-admission mode only** (corrected, second pass — research.md R16): `Orchestrator.
  spawn_issue_on_worker_host/5`, immediately before `Task.Supervisor.start_child/2`, calls `acquire_issue/2`
  **only when the issue's id is not already present in `state.claimed`**. Calls `bindle work claim <id>
  --owner <owner>` with **no** `--worktree`/`--branch` argument (§3 of `symphony-projection-v1.md`'s sibling
  contract; research.md R6). On `:ok`, proceed to spawn exactly as today. On `{:error, _}`, log at
  `Logger.debug` (matching the existing no-worker-capacity log level) and return `state` unchanged — the
  issue is simply not dispatched this cycle, and remains a candidate on the next poll. **When the issue's id
  IS already present in `state.claimed`** (a continuation retry, §9a's data-model.md entry) — `spawn_issue_
  on_worker_host/5` MUST NOT call `acquire_issue/2` at all; it proceeds directly to `Task.Supervisor.
  start_child/2`, reusing the already-held claim. This branch is required, not optional: `work_item_claims`'
  primary key is `work_item_id` alone, so a second `claim()` against an already-claimed task is rejected
  even from the same owner.
- **Re-validation before dispatch — same fresh-admission/continuation-retry split** (corrected, second pass
  — research.md R16): `Orchestrator.retry_candidate_issue?/2` (reached via `revalidate_issue_for_dispatch/3`
  → `refresh_issue_for_dispatch/1`, the exact function shared by both `dispatch_issue/4` and `handle_active_
  retry/4`) MUST require `dispatchable = true` only when the issue's id is not already in `state.claimed`;
  for an issue already in `state.claimed`, it MUST use `Issue.routed?/2` (label match + `continuation_
  allowed`, data-model.md §4) plus the existing terminal/active/missing-from-tracker checks instead.
- **Release — single call site**: `Tracker.release_issue/2` is invoked from exactly one internal function,
  `Orchestrator.release_issue_claim/2`, reached from every release path:
  - `terminate_running_issue/3`'s `nil` and catch-all branches already call `release_issue_claim/2` today
    (only an id is available there).
  - `terminate_running_issue/3`'s found-running-entry branch — today it duplicates
    `release_issue_claim/2`'s `claimed`/`blocked`/`retry_attempts`-clearing logic inline instead of
    delegating to it. This feature changes that branch to delegate to `release_issue_claim/2` (using the
    id from the running entry) so it also passes through the one call site, instead of adding a second,
    independent `Tracker.release_issue/2` call directly in that branch — the latter would double-call the
    external release for a single logical termination event.
  - `reconcile_blocked_issue_state/4`'s three direct calls to `release_issue_claim(state, issue.id)` are
    unchanged in shape and already pass through the one call site.
- **Acquire-success / spawn-failure compensation** (new, §3 below): `spawn_issue_on_worker_host/5`'s
  `{:error, reason} ->` branch (`Task.Supervisor.start_child/2` itself failing) now calls
  `release_issue_claim/2` before calling `schedule_issue_retry/4`.
- **Not called for the ordinary crash-mid-run retry**: a worker that already started and is being retried
  with its existing workspace/branch and existing Bindle claim intentionally reused — this is a distinct
  case from spawn-failure compensation above (research.md R7).

## 3. Acquire-success / spawn-failure compensation

**Problem**: `acquire_issue/2` succeeds, then `Task.Supervisor.start_child/2` itself fails
(`spawn_issue_on_worker_host/5`'s `{:error, reason} ->` branch). Today this branch schedules a retry with
no release (correct today — no adapter implements `acquire_issue/2`). Once acquisition runs immediately
before this same spawn call, a spawn failure after successful acquisition leaves a Bindle claim held by
this owner while Symphony's own `state.claimed` was never set for it (that branch never touches
`state.claimed`) — the scheduled retry's own next `acquire_issue/2` attempt would then be rejected by
Bindle as already-claimed by this same owner, deadlocking the issue against its own retry.

**Contract**: in `spawn_issue_on_worker_host/5`'s `{:error, reason} ->` branch, call
`Tracker.release_issue/2` (via `release_issue_claim/2`) for this issue's id **before** calling
`schedule_issue_retry/4` — but only when `acquire_issue/2` was actually invoked for this attempt (i.e. a
complete no-op for every adapter not implementing the callback pair, consistent with FR-005).

## 4. Bindle CLI wrapper (`SymphonyElixir.Bindle.Cli`)

```elixir
@spec claim(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t(), owner :: String.t()) ::
        {:ok, String.t()} | {:error, term()}
@spec release(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t(), owner :: String.t()) ::
        {:ok, String.t()} | {:error, term()}
```

- `claim/4` invokes `bindle work claim <id> --owner <owner>` with `cd: repo_path` — no `--worktree` or
  `--branch` argument; this feature has no truthful value for either at acquisition time and does not add
  a post-claim metadata-enrichment mechanism to supply one later (research.md R6). `--worktree`/`--branch`
  are documented as optional on Bindle's side (`task-write-surface.md`), so omitting them is a fully
  supported call shape, not a partial one.
- `release/4` invokes `bindle work release <id> --owner <owner>` with `cd: repo_path`.
- **`done/3` and `publish/2` (restored, second correction pass — research.md R17/R18)**:
  ```elixir
  @spec done(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  @spec publish(repo_path :: String.t(), bindle_bin :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  ```
  `done/3` invokes `bindle work done <id>` with `cd: repo_path` — **no `--owner` argument**: Bindle's `done`
  write surface has no ownership/claim requirement (verified `contracts/task-write-surface.md`/
  `symphony_projection.py`'s `complete_task()`). `publish/2` invokes `bindle work publish` with `cd:
  repo_path` — also no `--owner` argument. **Both are called only from `SymphonyElixir.Bindle.AgentTool`
  (§9 below) — never from `acquire_issue/2`/`release_issue/2` or any other orchestrator-owned code path**;
  the claim/release seam remains scoped exclusively to `claim`/`release` (FR-018).
- Exit code `0` → `{:ok, output}`. Exit code non-zero → `{:error, {:bindle_cli_failed, exit_code,
  output}}`, where `output` is stderr+stdout combined (`stderr_to_stdout: true`) so the `bindle work
  <verb>: <reason>` message is captured for logging without the caller needing to parse it further.
  `System.cmd/3` raising (binary not found, `cd:` path invalid) → rescued to `{:error,
  {:bindle_cli_unavailable, exception}}`.
- **Testability**: resolved via `Application.get_env(:symphony_elixir, :bindle_cli_module,
  SymphonyElixir.Bindle.Cli)`, exactly mirroring `gitlab/adapter.ex`'s existing `:gitlab_client_module`
  pattern, so orchestrator/adapter tests can inject a stub without an installed `bindle` binary.

## 5. Projection reader (`SymphonyElixir.Bindle.Projection`)

```elixir
@spec open_and_validate(path :: String.t()) :: :ok | {:error, term()}
@spec fetch_by_states(path :: String.t(), state_names :: [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
@spec fetch_by_ids(path :: String.t(), issue_ids :: [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
@spec list_ids(path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
```

- Every function opens its own short-lived read-only connection and closes it before returning — no
  long-lived open connection is held between polls (avoids the "long-lived reader can cause a concurrent
  publish() to fail" hazard Bindle's own contract doc warns about).
- `open_and_validate/1` performs the connection-open + `PRAGMA user_version` check only, used by
  `validate_config/1` (§8) to fail fast at configuration time, independent of any actual row fetch.
- `fetch_by_states/2` / `fetch_by_ids/2` query `task_projection` by column name (never positionally,
  FR-002), map rows per data-model.md §1, and return `{:ok, [Issue.t()]}` — a query returning zero rows is
  `{:ok, []}`, not an error. **A structurally invalid row (missing/empty required field, unparseable
  `created_at`) makes the whole fetch return `{:error, _}`, never a silently-shortened `{:ok, [...]}`**
  (data-model.md §1, research.md R14).
- `list_ids/1` is new (§7): returns every `id` currently in `task_projection`, regardless of `dispatchable`
  — used only by startup reconciliation, never by the ordinary poll path.
- Any connection-open failure, schema-version mismatch, or query error at any of these functions returns
  `{:error, _}`, routed through Symphony's existing tracker/source failure handling by the orchestrator's
  existing poll-failure path.

## 6. Owner identity (`SymphonyElixir.Bindle.Owner`)

```elixir
@spec id(owner_id_path :: String.t()) :: {:ok, String.t()} | {:error, term()}
```

- Reads the persisted owner-identity string from `owner_id_path`. If the file does not exist, generates
  a new opaque value, writes it, and returns it. **If the file exists but is corrupt or empty, returns
  `{:error, {:corrupt_owner_identity, owner_id_path}}` — it MUST NOT silently generate a replacement**
  (data-model.md §5, research.md R4). Callers (`acquire_issue/2`, `release_issue/2`, startup
  reconciliation) treat this error as a hard configuration failure, not a retryable transient one.

## 7. Startup reconciliation (new)

```elixir
@spec reconcile_stale_claims(repo_path :: String.t(), bindle_bin :: String.t(), owner_id_path :: String.t(),
                               projection_path :: String.t()) :: :ok | {:error, term()}
```

Runs once at Symphony startup, before normal polling begins, only when `tracker.kind: bindle` is active:

1. Resolve the persisted owner identity (§6); a corrupt/empty identity fails startup loud, per §6.
2. Call `Bindle.Projection.list_ids/1` (§5) against the configured projection. A read/schema-version
   failure here returns `{:error, _}` and MUST surface as the same distinguishable tracker/source failure
   an ordinary poll failure would — reconciliation MUST NOT silently skip recovery or silently proceed.
3. For each id returned, call `Bindle.Cli.release/4` (§4) with the persisted owner identity. Every call is
   attempted regardless of any individual call's own success/failure — a per-task release failure is
   logged and does not abort the sweep for the remaining ids.
4. This is a blind, projection-wide sweep with **no local record of which tasks this deployment previously
   claimed** — Bindle's own safe-release guarantee (releasing a task not held by this owner is a no-op)
   makes such a record unnecessary (data-model.md §6, research.md R5).
5. **Bounded per-id retry on individual failure (corrected, second pass — research.md R19)**: an id whose
   release call fails in step 3 is not left unretried until the next full process restart. Schedule a
   bounded number of follow-up release-only retries for exactly that id, reusing the orchestrator's
   existing `schedule_issue_retry/4` timer/backoff primitive — no new scheduling mechanism, no local ledger.
   Normal polling begins immediately after step 3 completes and is not blocked by these follow-up retries.
   If the bounded budget is exhausted without success, log a persistent, operator-visible failure naming
   the specific task id — this contract MUST NOT be read as claiming such a case is "recovered without
   manual intervention."

## 8. Config validation contract

`SymphonyElixir.Bindle.Adapter.validate_config/1` MUST:

1. Resolve `repo_path` (default `Config.workflow_dir()`, data-model.md §7) and resolve the projection
   `path` relative to it (default `<repo_path>/.bindle-work/symphony-projection.sqlite3`) — never
   independently relative to `Config.workflow_dir()` (research.md R15).
2. Call `Projection.open_and_validate/1` against the resolved path and propagate its result — surfaces a
   missing/incompatible/unreadable projection as a configuration-time failure, not merely a poll-time one.
3. Resolve the owner-identity path (`Owner.id/1`, §6) and propagate a corrupt-identity error as a
   configuration-time failure.

This mirrors `Local.Adapter.validate_config/1`'s existing validate-then-delegate shape, with the
correction that neither `repo_path` nor the projection `path` is treated as a required-with-no-default
field now that both have a well-grounded default (research.md R15).

## 9. Agent-invoked task-completion tool (restored, second correction pass — `SymphonyElixir.Bindle.AgentTool`, research.md R17/R18)

```elixir
@spec tool_specs() :: [map()]
@spec execute(tool :: String.t(), arguments :: map(), opts :: keyword()) :: map()
```

- Exposed through `SymphonyElixir.Bindle.Adapter`'s `agent_tool_specs/0`/`execute_agent_tool/3`
  implementation, exactly one tool spec, mirroring the shape every other provider's `AgentTool` module
  already uses (e.g. `linear/agent_tool.ex`).
- **Target resolution**: the implementation MUST read the target task id exclusively from
  `Keyword.fetch!(opts, :issue).id` — the session-bound `Tracker.Issue` `SymphonyElixir.ClaudeCode.MCPServer`
  fixes at that listener's `start_link/1` time and passes into every `execute_agent_tool/3` call. The tool's
  `inputSchema` MUST NOT declare a task-id parameter at all — there is nothing for a model-supplied argument
  to override, by construction, not merely by server-side validation.
- **Behavior**: calls `Bindle.Cli.done/3` (§4) for the resolved id. On success, calls `Bindle.Cli.publish/2`
  (§4) as a best-effort follow-up. Returns a result distinguishing three outcomes: `done` failed (the tool's
  own failure result, e.g. `{:error, {:bindle_cli_failed, _, _}}` or `not_open`); `done` succeeded and
  `publish` succeeded (ordinary success); `done` succeeded but `publish` failed (success for the completion
  itself, with the publish failure surfaced as a distinct field in the result payload — never re-attempted
  by retrying `done`, per §4's rationale).
- **What this tool does not do**: it does not infer completion from any mechanical signal (test results,
  process exit, evidence) — it fires only in direct response to the agent's own explicit tool invocation; it
  exposes no milestone review/acceptance operation; it reads no dependency/blocking/evidence state; it
  shares no code path with `acquire_issue/2`/`release_issue/2` beyond the `Bindle.Cli` wrapper module.
