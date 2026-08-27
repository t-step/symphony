# Contract: `SymphonyElixir.Bindle.Adapter`

This contract fixes the shape of the new adapter and the two new `Tracker` behaviour callbacks. It does
not restate `002-bindle-integration`'s architectural contract (frozen, authoritative) — it makes that
contract's abstract requirements concrete against this repository's actual current code.

## 1. `Tracker` behaviour addition

```elixir
@callback acquire_issue(Issue.t(), keyword()) :: :ok | {:error, term()}
@callback release_issue(Issue.t(), keyword()) :: :ok | {:error, term()}

@optional_callbacks acquire_issue: 2, release_issue: 2
```

`Tracker.acquire_issue/2` and `Tracker.release_issue/2` (new public functions on `SymphonyElixir.Tracker`
itself, mirroring the existing `Tracker.fetch_issues_by_states/1` delegation pattern) resolve the active
adapter and call through only if it exports the callback (`Code.ensure_loaded?/1` +
`function_exported?/3`, the same pattern `Tracker.validate_config/1` already uses at line 100); otherwise
they return `:ok` unconditionally — a complete no-op.

## 2. Orchestrator call sites

- **Acquire**: `Orchestrator.spawn_issue_on_worker_host/5`, immediately before
  `Task.Supervisor.start_child/2` (orchestrator.ex:960-963). On `:ok`, proceed to spawn exactly as today.
  On `{:error, _}`, log at `Logger.debug` (matching the existing no-worker-capacity log level at
  orchestrator.ex:952) and return `state` unchanged — the issue is simply not dispatched this cycle, and
  remains a candidate on the next poll.
- **Release**: `Orchestrator.terminate_running_issue/3` and `Orchestrator.release_issue_claim/2`
  (orchestrator.ex:554-579, 1230-1237) — call `Tracker.release_issue/2` at the top of each, before the
  existing in-memory bookkeeping mutation, passing the issue struct available at that call site (present
  in `state.running`'s entry, or reconstructable from the id where only an id is available).
- **Not called**: any retry-scheduling path that keeps the same workspace/branch — verified there is no
  separate "retry scheduled" call site distinct from the two release points above; retries reuse the
  existing running/claimed entry without invoking either release point until the retry itself is
  exhausted.

## 3. Bindle CLI wrapper (`SymphonyElixir.Bindle.Cli`)

```elixir
@spec claim(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t(), owner :: String.t(),
             opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
@spec release(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t(), owner :: String.t()) ::
        {:ok, String.t()} | {:error, term()}
@spec done(repo_path :: String.t(), bindle_bin :: String.t(), id :: String.t()) ::
        {:ok, String.t()} | {:error, term()}
```

- `claim/5` invokes `bindle work claim <id> --owner <owner> [--worktree <value>]` (no `--branch` — see
  research.md R6) with `cd: repo_path`.
- `release/4` invokes `bindle work release <id> --owner <owner>` with `cd: repo_path`.
- `done/3` invokes `bindle work done <id>` with `cd: repo_path` — provided for completeness per
  `002-bindle-integration`'s Key Entities (Bindle's write surface), but this feature does not call it from
  any orchestrator-owned code path (FR-017/FR-018 — a `done` transition is a lifecycle-mutation write,
  scoped to the agent-invoked tool boundary in §5 below, not the orchestrator-owned acquire/release seam).
- Exit code `0` → `{:ok, output}`. Exit code non-zero → `{:error, {:bindle_cli_failed, exit_code,
  output}}`, where `output` is stderr+stdout combined (`stderr_to_stdout: true`) so the `bindle work
  <verb>: <reason>` message is captured for logging without the caller needing to parse it further.
  `System.cmd/3` raising (binary not found, `cd:` path invalid) → rescued to `{:error,
  {:bindle_cli_unavailable, exception}}`.
- **Testability**: resolved via `Application.get_env(:symphony_elixir, :bindle_cli_module,
  SymphonyElixir.Bindle.Cli)`, exactly mirroring `gitlab/adapter.ex:47-48`'s `:gitlab_client_module`
  pattern, so orchestrator/adapter tests can inject a stub without an installed `bindle` binary.

## 4. Projection reader (`SymphonyElixir.Bindle.Projection`)

```elixir
@spec open_and_validate(path :: String.t()) :: :ok | {:error, term()}
@spec fetch_by_states(path :: String.t(), state_names :: [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
@spec fetch_by_ids(path :: String.t(), issue_ids :: [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
```

- Every function opens its own short-lived read-only connection and closes it before returning — no
  long-lived open connection is held between polls (avoids the "long-lived reader can cause a concurrent
  publish() to fail" hazard Bindle's own contract doc warns about, per the Bindle-side grounding pass).
- `open_and_validate/1` performs the connection-open + `PRAGMA user_version` check only, used by
  `validate_config/1` (data-model.md §7) to fail fast at configuration time, independent of any actual
  row fetch.
- `fetch_by_states/2` / `fetch_by_ids/2` query `task_projection` by column name (never positionally,
  FR-002), map rows per data-model.md §1, and return `{:ok, [Issue.t()]}` — a query returning zero rows is
  `{:ok, []}`, not an error (mirrors every other adapter's existing empty-result contract).
- Any connection-open failure, schema-version mismatch, or query error at any of these three functions
  returns `{:error, _}`, routed through Symphony's existing tracker/source failure handling by the
  orchestrator's existing poll-failure path (no new failure-handling code needed at the orchestrator
  level — this adapter's errors flow through the same `{:error, _}` contract every adapter's
  `fetch_issues_by_*` already returns).

## 5. Scoped lifecycle-mutation tool (`SymphonyElixir.Bindle.AgentTool`)

Mirrors `Local.AgentTool` exactly in shape (FR-018): one tool, scoped to `opts[:issue]`'s bound id, calling
`Bindle.Cli.done/3` (the one Bindle-owned write verb a coding-agent session's own progress report maps
onto — `002-bindle-integration`'s Key Entities name `done` as part of Bindle's supported write surface
alongside `claim`/`release`). No arbitrary-id targeting, no new orchestrator-owned API — this tool is
agent-invoked and host-executed through the existing `agent_tool_specs/0`/`execute_agent_tool/3` boundary,
exactly like every other adapter's own lifecycle tool.

## 6. Config validation contract

`SymphonyElixir.Bindle.Adapter.validate_config/1` MUST:

1. Reject a `provider` map missing a non-empty `repo_path` — `{:error, :invalid_bindle_repo_path}`.
2. Reject a `provider` map with an empty/missing resolved projection `path` — `{:error,
   :invalid_bindle_projection_path}` (defends against an explicitly-configured empty string; the default
   itself is never empty).
3. Call `Projection.open_and_validate/1` against the resolved path and propagate its result — surfaces a
   missing/incompatible/unreadable projection as a configuration-time failure, not merely a poll-time one.

This mirrors `Local.Adapter.validate_config/1`'s existing two-step validate-then-delegate shape.
