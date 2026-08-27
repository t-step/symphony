# Phase 0 Research: Bindle-Backed Tracker Adapter Implementation

All items below were resolved by direct inspection of Symphony's current source (`development` HEAD
`9eebdb8`) and Bindle's current source (`~/Developer/bindle` HEAD `dace8f6`), not assumed. No
`NEEDS CLARIFICATION` markers remain.

## R1: Read-only SQLite access to the published projection

**Decision**: Use the existing `exqlite` dependency (`mix.lock`, `~> 0.30`, resolving `0.40.0`), opening
the projection with a read-only URI connection (`Exqlite.open(path, mode: :readonly)` /
equivalent `file:<path>?mode=ro` URI form) rather than a plain file-path connection.

**Rationale**: `exqlite` is already present in the project's dependency tree (confirmed in `mix.lock`
before this feature adds anything), so FR-002's "opened exclusively via SQLite's own read-only open mode"
requirement is satisfiable with zero new dependencies. A plain-path connection would open the file
read-write by default and rely on the adapter simply "not issuing a write" — insufficient per FR-002,
which requires the connection itself be opened read-only.

**Alternatives considered**: Shelling out to the `sqlite3` CLI for reads — rejected: adds a second
external-process dependency for no benefit when a proper read-only driver connection is available and
already vendored.

## R2: Schema-version validation

**Decision**: Read `PRAGMA user_version` from the opened connection immediately after connecting, before
any `task_projection` query, and fail closed (return `{:error, {:unsupported_projection_version, got}}`)
unless it equals the one version this adapter supports.

**Rationale**: Verified directly against Bindle's actual publisher (`src/bindle/symphony_projection.py`):
the projection sets `PRAGMA user_version = 1` in the same transaction as the table rewrite, matching
FR-002's "schema-version marker" requirement exactly — there is no separate version column or table to
check instead.

**Alternatives considered**: None — this is Bindle's actual, already-shipped mechanism; no alternative
design was evaluated since the marker's shape is fixed by Bindle's side, not chosen here.

## R3: Bindle CLI invocation shape

**Decision**: Invoke via `System.cmd("bindle", ["work", "claim"|"release"|"done", id, ...], cd:
repo_path, stderr_to_stdout: true)`, interpreting exit code `0` as success and any non-zero exit as a
distinguishable `{:error, {:bindle_cli_failed, exit_code, output}}`; wrap `System.cmd/3` raising (binary
not found) as `{:error, {:bindle_cli_unavailable, _}}`.

**Rationale**: Verified directly against Bindle's actual CLI (`src/bindle/cli.py`): `bindle` is a
console-script entry point (`pyproject.toml` `[project.scripts]`), not a Python-importable module and not
a standalone binary with a repo-path flag. Every `work` subcommand resolves its target ledger from the
invoking process's working directory (`repo.py`'s `get_repo_info(cwd=None)` always resolving
`os.getcwd()`), with no `--repo`/`--repo-root` flag on any subcommand. There is no JSON output mode
anywhere in `cli.py`'s argument parser — the exit-code/stderr convention (`0` success, `1` failure with
`bindle work <verb>: <reason>` on stderr) is Bindle's own committed, documented contract, not an
implementation detail. `cd:` on `System.cmd/3` is therefore the only correct way to target a specific
Bindle-managed repository.

**Alternatives considered**: Parsing structured output — rejected, no such mode exists today; adding one
would be Bindle-side scope creep this feature's Non-Goals explicitly forbid. Passing a repo path as a CLI
argument — rejected, no such flag exists on any `work` subcommand as of Bindle HEAD `dace8f6`.

## R4: Owner identity

**Decision**: A single, randomly-generated, opaque string, generated once and persisted to a small file
under the deployment's workflow directory (default `.symphony/bindle_owner_id`, configurable), read on
every `acquire_issue/2`/`release_issue/2` call and reused unchanged across restarts.

**Rationale**: Bindle's `claim()`/`release_claim()` treat `owner` as an unverified, caller-supplied string
with no identity/auth system behind it (`specs/003-symphony-task-integration/contracts/task-write-
surface.md`, Bindle repo) — any stable string this deployment consistently reuses satisfies the contract.
Persisting it (rather than deriving it from ephemeral process state like a PID or hostname) is required
for FR-011's startup-time stale-claim reconciliation to find *this deployment's own* claims after a
restart, since a PID or hostname is not guaranteed stable across a crash/restart cycle in every deployment
environment this fork targets.

**Alternatives considered**: Deriving owner identity from the machine hostname — rejected: not unique
across two deployments sharing a host (e.g. containerized environments), and not stable across a
container restart with a fresh hostname in some orchestration setups. A configured, operator-supplied
value only, with no generated fallback — rejected: adds an operator setup step FR-010 does not require;
the generated-and-persisted approach needs zero new operator configuration for the common case while
still allowing an explicit override.

## R5: Startup-time stale-claim reconciliation

**Decision**: On Symphony startup, if `tracker.kind: bindle` is active, read the local claims ledger (R7)
and call `bindle work release <id> --owner <owner>` for every entry still recorded, before the orchestrator
begins normal polling; treat a `not_found`/`already released` outcome as a benign no-op, not an error.

**Rationale**: This is the concrete mechanism FR-011 requires and `002-bindle-integration` FR-015
explicitly left as an open design question — Bindle's claims carry no expiry (verified: `work_ledger.py`'s
`claim()`/`work_item_claims` schema has no TTL/expiry column), so nothing releases a crashed instance's
stale claim except an explicit `release` call, and the only record of "what did *this* instance claim"
that survives a crash is the local ledger this feature adds.

**Alternatives considered**: Relying on a future Bindle-side claim-expiry mechanism — rejected: no such
mechanism exists today, and adding one would be Bindle-side scope creep, explicitly out of scope. Skipping
crash recovery entirely — rejected: leaves a real, previously-identified gap (`002-bindle-integration`'s
edge cases) unresolved, and FR-011 requires it.

## R6: Acquisition call-site timing and parameters

**Decision**: Call `acquire_issue/2` from `Orchestrator.spawn_issue_on_worker_host/5`, immediately before
`Task.Supervisor.start_child/2` (orchestrator.ex:960-963), passing the issue's pre-computed
`Workspace.workspace_key/1` value (a pure function of `issue.identifier`, confirmed at
`elixir/lib/symphony_elixir/workspace.ex:265-278`, computable with no workspace directory materialized
yet) as the claim's `--worktree` argument; no `--branch` argument is supplied at this stage (Symphony does
not yet compute a branch name before workspace creation).

**Rationale**: `002-bindle-integration` FR-015 identifies "where in the dispatch sequence enough
information exists to satisfy Bindle's actual claim parameters" as a genuinely open design question, since
the real workspace path only exists after the `Task` is spawned. `workspace_key/1` is the one piece of
per-issue, pre-spawn information that is both stable and already computed identically at workspace-creation
time (`Workspace.create_for_issue/2` calls the same function internally), so passing it satisfies Bindle's
optional `--worktree` parameter without inventing new pre-spawn state.

**Alternatives considered**: Deferring `acquire_issue/2` until after `Task.Supervisor.start_child/2`
succeeds — rejected: this would let a worker begin running before Bindle's own claim arbitration has
resolved, reintroducing exactly the double-dispatch race FR-015 exists to close (User Story 2). Passing no
`--worktree` at all — rejected as unnecessarily lossy: the parameter is optional on Bindle's side but
free to supply here and gives Bindle-side operators useful context for a claimed task.

## R7: Release semantics on CLI failure

**Decision**: `release_issue/2` always clears the local claims-ledger entry for the issue, regardless of
whether the underlying `bindle work release` CLI call itself succeeds; a CLI failure is logged, and its
`{:error, _}` is still returned to the caller, but never blocks Symphony's own in-memory release
bookkeeping (`release_issue_claim/2`, `terminate_running_issue/3`) from proceeding.

**Rationale**: Symphony's own reconciliation must never get stuck believing it still holds a claim it has
already decided to release — the orchestrator's in-memory state and Bindle's durable claim state are two
separate concerns, and a transient failure calling Bindle (e.g. the `bindle` binary unreachable at that
moment) must not corrupt the former. A Bindle-side stale claim left behind by a failed release call is
exactly what R5's startup-time reconciliation exists to eventually clean up — not a case requiring
synchronous retry here.

**Alternatives considered**: Retrying the release call synchronously before proceeding — rejected: adds
latency and complexity to the orchestrator's hot release path for a failure mode R5 already recovers from
on next startup; per Constitution II, the smaller-delta option is preferred when outcomes are equivalent.

## R8: Splitting admission from continuation/routing

**Decision**: Replace `Tracker.Issue.routable?/2`'s single combined boolean with two functions:
`dispatchable?/1` (returns `issue.dispatchable`, admission-only) and `routed?/2` (label match, plus — for
adapters that populate an assignment signal — an assignment-still-matches check), keeping `routable?/2` as
a thin `dispatchable?(issue) and routed?(issue, labels)` composition for the one legitimate admission-path
caller (`candidate_issue?/3`) so that call site needs no logic change, only continued use of the same name.
`Orchestrator.reconcile_issue_state/4`, `reconcile_blocked_issue_state/4`, and
`AgentRunner.continue_with_issue?/2` are changed to call `routed?/2` directly instead of `routable?/2`.

**Rationale**: Verified directly (`tracker/issue.ex:53-60`, `orchestrator.ex:421-441,456-474,860-877`,
`agent_runner.ex:174-191,202-204`) that all four call sites currently share one predicate, and that three
of the four (the continuation/release ones) must stop consulting `dispatchable` per FR-013/FR-014, while
the fourth (`candidate_issue?/3`, reached only via `should_dispatch_issue?/4`'s own additional
not-already-running/claimed/blocked guards) must keep consulting it per FR-015. Composing `routable?/2`
from the two new functions, rather than deleting it, means `candidate_issue?/3` requires zero logic change
— only the three continuation call sites change what they call.

**Alternatives considered**: Adding a new `Issue.continuable?/2` function alongside the untouched
`routable?/2`, duplicating the label-match logic — rejected: two independent implementations of the same
label-match rule risk drifting out of sync; composing from a shared `routed?/2` avoids that.

## R9: Per-adapter continuation-signal compatibility

**Decision**: Add a `routed_by_assignment: boolean()` field to `Tracker.Issue` (default `true`, meaning
"this adapter has no assignment-reassignment concept, so assignment never blocks continuation"), populated
by Linear's client (`elixir/lib/symphony_elixir/linear/client.ex`) with its existing
assignee-still-matches computation, and left at its default by every other adapter. `routed?/2` (R8)
consults this field in addition to label match.

**Rationale**: Verified directly that Linear's client already computes an assignee-match condition as
part of its existing `dispatchable` derivation (`linear/client.ex`, `dispatchable?/4`'s `assignee`/
`assignee_filter` parameters) — today that check is folded into the single `dispatchable` boolean, which
is exactly why splitting `dispatchable` from routing without also carrying this signal forward would
silently drop Linear's real, load-bearing reassignment-stop behavior (identified as a genuine risk in
`002-bindle-integration`'s Assumptions, citing research.md R11 of that spec). Verified Asana's adapter has
no equivalent assignment-based continuation signal today (its continuation-relevant distinction is
`completed`-vs-section-name, which is a `state`/label concern already covered by the existing label-match
path, not an assignment concern) — so Asana needs no equivalent field population, only confirmation via
its own test suite that this feature's change does not alter its behavior.

**Alternatives considered**: Computing the assignment-still-matches check independently inside
`Orchestrator`/`AgentRunner` by comparing `issue.assignee_id` against configured settings at continuation
time — rejected: `assignee_id` alone does not carry the adapter-specific matching rule (e.g. Linear's own
filter semantics), and reimplementing that rule outside the adapter that already computes it correctly
risks exactly the kind of drift Constitution II warns against.

## R10: Config schema for `tracker.kind: bindle`

**Decision**: Add `resolve_tracker_provider("bindle", settings, provider)` to `config/schema.ex`,
mirroring the existing `"local"` clause's shape (`config/schema.ex:525-534`): resolve a projection `path`
(default `.bindle-work/symphony-projection.sqlite3`, relative to `workflow_dir()`), plus three
Bindle-specific keys with no upstream-shared equivalent: `repo_path` (the Bindle repository root the CLI
is invoked with `cd:`, required, no default — there is no sensible default for an external repo location),
`bindle_bin` (default `"bindle"`, overridable for a non-`$PATH` install), and `owner_id_path` (default
`.symphony/bindle_owner_id`, relative to `workflow_dir()`).

**Rationale**: Matches the exact structural precedent every other adapter already uses for its own
provider-specific settings (Linear's `endpoint`/`api_key`/`assignee`, Local's `path`) — no new
configuration mechanism, just one more `resolve_tracker_provider/3` clause.

**Alternatives considered**: A dedicated top-level `bindle:` config section outside `tracker.provider` —
rejected: every other adapter's settings live inside `tracker.provider`; a separate section would break
FR-006's "distinct, explicit configuration choice" requirement's own consistency with how every other
tracker kind is already configured.

## R11: Test strategy for the SQLite and CLI boundaries

**Decision**: For projection tests, create a real temporary SQLite file per test with the exact
`task_projection` schema and `PRAGMA user_version = 1` (via `exqlite` directly in test setup), rather than
mocking the database boundary — this exercises the adapter's actual read-only-open and schema-validation
code paths, not a stand-in. For CLI tests, inject a `:bindle_cli_module` application-env override
(mirroring the already-existing `:gitlab_client_module` pattern, `gitlab/adapter.ex:47-48`) so orchestrator
integration tests can stub claim/release outcomes without requiring an installed `bindle` binary in CI or
local `mix test` runs; a small number of `bindle_cli_test.exs` unit tests exercise the real
`System.cmd/3`-based wrapper's argument construction and exit-code/output interpretation directly (mocking
`System.cmd/3` itself is unnecessary — the wrapper's own logic, given a fake `bindle_bin` pointing at a
tiny test fixture script, is cheaply testable without a real Bindle installation).

**Rationale**: Matches the repository's own stated preference (spec.md's Testing section, and the
project's general instruction to prefer real fixtures over mocking away architectural boundaries) while
keeping the test suite runnable without a developer-local Bindle install, consistent with how every other
hosted adapter (GitHub/GitLab/Jira/Linear/Asana) already tests its own HTTP boundary via an injectable
client module rather than live network calls.

**Alternatives considered**: Requiring a real installed `bindle` binary for CLI tests — rejected per the
task's own instruction not to make the suite depend on a developer-local Bindle binary absent an existing
clean convention for it (none exists in this repo today). Mocking the SQLite layer entirely (e.g. a
`Mox`-based fake) — rejected: the read-only-open and `PRAGMA user_version` behaviors are exactly the
things worth verifying against a real SQLite file, and `exqlite` against a small temp file is cheap.
