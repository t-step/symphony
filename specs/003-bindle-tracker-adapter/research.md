# Phase 0 Research: Bindle-Backed Tracker Adapter Implementation

All items below were resolved by direct inspection of Symphony's current source (`development` HEAD
`9eebdb8`) and Bindle's current source (`~/Developer/bindle` HEAD `dace8f6`, specifically
`src/bindle/work_ledger.py`, `src/bindle/symphony_projection.py`, and
`specs/003-symphony-task-integration/contracts/task-write-surface.md`), not assumed. No
`NEEDS CLARIFICATION` markers remain.

**Correction pass (2026-08-27)**: R4–R7 below were rewritten, and R12–R15 added, after a review pass
found the first draft's local claims-ledger design was not crash-safe, its acquisition call supplied a
`--worktree` value Bindle's own reconciliation would misinterpret as a real filesystem path, and it was
silent about a genuine acquire-success/spawn-failure race and a release-callback double-call risk. Every
correction below is re-verified directly against Bindle's and Symphony's actual code, not reapplied
blindly from a review prompt. None of these corrections reopen `002-bindle-integration` — they make this
feature conform to it more closely (in particular FR-013/User Story 5's semantic-judgment boundary, which
the first draft's `done`-tool design would have crossed).

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

**Rationale**: Verified directly against Bindle's actual publisher (`src/bindle/symphony_projection.py`
lines 38-46): the projection sets `PRAGMA user_version = 1` (`_PROJECTION_VERSION = 1`) in the same
transaction as the table rewrite, matching FR-002's "schema-version marker" requirement exactly — there is
no separate version column or table to check instead.

**Alternatives considered**: None — this is Bindle's actual, already-shipped mechanism; no alternative
design was evaluated since the marker's shape is fixed by Bindle's side, not chosen here.

## R3: Bindle CLI invocation shape

**Decision**: Invoke via `System.cmd("bindle", ["work", "claim"|"release", id, "--owner", owner, ...],
cd: repo_path, stderr_to_stdout: true)`, interpreting exit code `0` as success and any non-zero exit as a
distinguishable `{:error, {:bindle_cli_failed, exit_code, output}}`; wrap `System.cmd/3` raising (binary
not found) as `{:error, {:bindle_cli_unavailable, _}}`.

**Rationale**: Verified directly against Bindle's actual CLI contract
(`specs/003-symphony-task-integration/contracts/task-write-surface.md`, and `src/bindle/work_ledger.py`'s
`claim()`/`release_claim()` it wraps): `bindle` is a console-script entry point, not a Python-importable
module and not a standalone binary with a repo-path flag. Every `work` subcommand resolves its target
ledger from the invoking process's working directory, with no `--repo`/`--repo-root` flag on any
subcommand. There is no JSON output mode — the exit-code/stderr convention (`0` success, `1` failure with
`bindle work <verb>: <reason>` on stderr) is Bindle's own committed, documented contract ("consistent with
`bindle`'s existing exit-code convention"), not an implementation detail. `cd:` on `System.cmd/3` is
therefore the only correct way to target a specific Bindle-managed repository.

**Alternatives considered**: Parsing structured output — rejected, no such mode exists today; adding one
would be Bindle-side scope creep this feature's Non-Goals explicitly forbid. Passing a repo path as a CLI
argument — rejected, no such flag exists on any `work` subcommand as of Bindle HEAD `dace8f6`.

## R4: Owner identity (revised)

**Decision**: A single, randomly-generated, opaque string, generated once and persisted to a small file
under the deployment's workflow directory (default `.symphony/bindle_owner_id`, configurable), read on
every `acquire_issue/2`/`release_issue/2` call and on startup-time reconciliation (R5), reused unchanged
across restarts. If the file exists but its contents are corrupt or empty (as opposed to simply not
existing yet), initialization MUST fail loud — a startup/configuration error — rather than silently
generating a replacement.

**Rationale**: Bindle's `claim()`/`release_claim()` treat `owner` as an unverified, caller-supplied string
with no identity/auth system behind it (`specs/003-symphony-task-integration/contracts/task-write-
surface.md`, "What this contract does not do" — "It does not add authentication, authorization, or
identity verification for `owner`") — any stable string this deployment consistently reuses satisfies the
contract. Persisting it (rather than deriving it from ephemeral process state like a PID or hostname) is
required for R5's startup-time reconciliation to use the same owner identity a prior run's claims were
made under. Failing loud on corrupt/empty state (rather than regenerating) is required because R5's
recovery mechanism depends on reusing the *same* identity a prior crashed run held claims under — silently
generating a new identity would make those prior claims permanently unrecoverable by any Bindle-safe
mechanism this feature provides, with no local trace that this ever happened.

**Alternatives considered**: Deriving owner identity from the machine hostname — rejected: not unique
across two deployments sharing a host, and not stable across a container restart with a fresh hostname in
some orchestration setups. Silently regenerating on corrupt/missing state — rejected per the rationale
above; this is exactly the kind of silent data loss Constitution VII's "verify fork behavior" spirit
warns against for a change this load-bearing.

## R5: Startup-time reconciliation (revised — projection enumeration, not a local ledger)

**Decision**: On Symphony startup, if `tracker.kind: bindle` is active, before the orchestrator begins
normal polling: read the current Bindle-facing projection (the same `Bindle.Projection` reader User Story
1 defines), enumerate every task id it currently lists, and call `bindle work release <id> --owner
<persisted-owner>` for each one. If the projection cannot be read or fails its schema-version check at
this point, surface the same distinguishable tracker/source failure an ordinary poll failure would
produce — do not silently proceed as if no recovery were needed.

**Rationale (why no local claims ledger)**: A first-draft design tracked "which tasks this deployment
believes it holds claims on" in a local JSON ledger, updated on every acquire/release. That design is not
actually crash-safe: a Bindle claim can succeed and the Symphony process can die before the local ledger
entry is even written, producing exactly the stale claim the ledger was meant to make recoverable, but
with *no local record of it* — the one failure mode the mechanism exists to handle is also the one mode
it cannot record. Re-verified directly against Bindle's actual guarantees
(`src/bindle/work_ledger.py:1187-1199`, `release_claim/2`'s docstring: "`DELETE FROM work_item_claims
WHERE work_item_id = ? AND owner = ?` — deleting zero rows (already released, or `owner` does not match
the recorded owner) is a no-op, never an error") and Bindle's projection membership rule
(`generate_external_projection()`, `work_ledger.py:1609-1613`: restricted to `archived_at IS NULL AND
type = 'task'`, a structural predicate independent of claim state — every non-archived task appears in
the projection regardless of whether it is currently claimed, unclaimed, or claimed by someone else; only
its `dispatchable` fact changes), a task this deployment could ever have claimed necessarily still appears
in the current projection if it remains live, and if it has since been archived, Bindle itself removes any
lingering claim row on archival (per the same ownership-boundary reasoning `002-bindle-integration`
already established for archived/reconciled state). This means Symphony does not need to know *which*
tasks it previously claimed to safely attempt releasing all of them — an unclaimed-by-this-owner release
is a documented no-op, not an error, so a blind, projection-wide, owner-scoped release sweep is both
sufficient and safe, with no local state to keep synchronized or lose in a crash.

**Alternatives considered**: The local-ledger design above — rejected for the crash-unsafety reason
detailed above. Relying on a future Bindle-side claim-expiry mechanism — rejected: no such mechanism
exists today (verified: `work_item_claims`'s schema carries no TTL/expiry column), and adding one would be
Bindle-side scope creep, explicitly out of scope. Skipping crash recovery entirely — rejected: leaves a
real, previously-identified gap (`002-bindle-integration`'s edge cases) unresolved.

## R6: Acquisition call-site timing and parameters (revised — no fabricated worktree metadata)

**Decision**: Call `acquire_issue/2` from `Orchestrator.spawn_issue_on_worker_host/5`, immediately before
`Task.Supervisor.start_child/2` (orchestrator.ex:960-963), invoking `bindle work claim <id> --owner
<owner>` with **neither** a `--worktree` nor a `--branch` argument.

**Rationale**: A first-draft design proposed passing `Workspace.workspace_key/1`'s pure, pre-spawn value
as the claim's `--worktree` argument, reasoning that the real workspace path does not exist yet at
acquisition time. Re-verified directly against Bindle's actual reconciliation logic
(`src/bindle/work_ledger.py:1290-1370`, the `stale_claim`/`corrupt_claim` detection pass): a claim's
recorded `worktree_path` is not an opaque label — Bindle's own reconciliation later resolves it with
`os.path.realpath` and checks it against a registered set of real Git worktree paths
(`_registered_worktree_paths/1`), and separately checks `os.path.isdir(worktree_path)` to flag a
`stale_claim` when the recorded path no longer exists. A Symphony `workspace_key` is a short, deliberately
non-path-like string (`Workspace.workspace_key/1`'s own docstring: a slug derived from `identifier`), not
a real filesystem/Git-worktree path — supplying it as `--worktree` would cause Bindle's own reconciliation
to flag every such claim as `stale_claim` (a fabricated path that is never a directory and never a
registered worktree), a false positive this feature must not manufacture. Both `--worktree` and `--branch`
are documented as optional on `claim` (`specs/003-symphony-task-integration/contracts/task-write-
surface.md`, "Claim"), and nothing in this feature's own scope has a truthful value for either at
acquisition time (the actual workspace directory is only created *after* the `Task` is spawned) — so the
correct, smallest-truthful choice is to omit both rather than invent one now for a metadata-enrichment
mechanism this feature does not otherwise need.

**Alternatives considered**: Passing `workspace_key/1` as `--worktree` (the first draft's choice) —
rejected per the false-staleness finding above. Deferring `acquire_issue/2` until after
`Task.Supervisor.start_child/2` succeeds, once the real workspace path is known, so a truthful
`--worktree` could be supplied — rejected: this would let a worker begin running before Bindle's own claim
arbitration has resolved, reintroducing exactly the double-dispatch race FR-015 (`002-bindle-integration`)
exists to close (User Story 2). A later, separate metadata-enrichment call updating the claim's
`worktree_path` once the real path exists — rejected as unnecessary scope: Bindle's contract documents no
such update operation, and this feature has no requirement that depends on Bindle knowing the real
workspace path.

## R7: Release semantics — single call site, retry-vs-spawn-failure distinction (revised)

**Decision**: `release_issue/2` is invoked from exactly one place in the orchestrator's own logic per
logical release event — see R13 for exactly where. It is **not** called merely because a retry is
scheduled for a worker that already started and is intentionally reusing its existing workspace/branch
(the ordinary crash-mid-run retry case). It **is** called as immediate compensation when acquisition
succeeded but the subsequent worker-spawn attempt itself failed before any workspace/attempt existed (see
R12) — a retry is scheduled in both cases, but only one of them is releasing a claim for work that never
actually started.

**Rationale**: A first-draft design proposed "always clear the local claims-ledger entry regardless of
the underlying CLI call's success," which no longer applies once R5 removes the local ledger. The real
requirement this correction preserves is narrower and more precise than the first draft's blanket "don't
release on retry" wording: `002-bindle-integration` FR-015's "not merely because a retry is scheduled"
language was written assuming the *only* kind of retry in play is the ordinary crash-mid-run one where a
workspace/branch is being reused — it was not written with the acquire-then-spawn-failure race in mind
(R12), where no workspace was ever created and nothing is actually being reused. Treating both retry kinds
identically (never releasing) would leave a real Bindle claim held indefinitely by an attempt that never
started, since the retry's own future acquisition attempt would then be rejected by Bindle as
already-claimed by this same owner — a self-inflicted deadlock, not a hypothetical one, verified directly
against `Orchestrator.spawn_issue_on_worker_host/5`'s actual `{:error, reason} ->` branch
(orchestrator.ex:993-999), which schedules `schedule_issue_retry/4` today with no release of any kind.

**Alternatives considered**: A local ledger with "always clear on release, regardless of CLI outcome" (the
first draft's design) — superseded by R5's removal of the ledger entirely; the underlying "don't get stuck
believing you hold a claim you meant to release" concern is instead handled by R5's startup reconciliation,
which needs no local bookkeeping to recover a genuinely stuck claim. Treating the spawn-failure case
identically to the crash-mid-run retry case (never releasing) — rejected per the deadlock finding above.

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
of the four (the continuation/release ones) must stop consulting `dispatchable` per FR-014/FR-015, while
the fourth (`candidate_issue?/3`, reached only via `should_dispatch_issue?/4`'s own additional
not-already-running/claimed/blocked guards) must keep consulting it per FR-016. Composing `routable?/2`
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

**Rationale**: Verified directly (`linear/client.ex:496-499`, `defp dispatchable?(state_name, blockers,
assignee, assignee_filter)`) that Linear's client already computes `assigned_to_worker?(assignee,
assignee_filter) and not blocked_before_dispatch?(state_name, blockers)` and folds the result straight
into `dispatchable` today — exactly why splitting `dispatchable` from routing without also carrying this
signal forward would silently drop Linear's real, load-bearing reassignment-stop behavior. Verified
Asana's adapter (`asana/client.ex:223`, `dispatchable: task["completed"] == false and
task["resource_subtype"] != "section"`) has no equivalent assignment-based continuation signal — its
continuation-relevant distinction is `completed`-vs-section-name, which is a `state`/label concern already
covered by the existing label-match path, not an assignment concern — so Asana needs no equivalent field
population, only confirmation via its own test suite that this feature's change does not alter its
behavior.

**Alternatives considered**: Computing the assignment-still-matches check independently inside
`Orchestrator`/`AgentRunner` by comparing `issue.assignee_id` against configured settings at continuation
time — rejected: `assignee_id` alone does not carry the adapter-specific matching rule (e.g. Linear's own
filter semantics), and reimplementing that rule outside the adapter that already computes it correctly
risks exactly the kind of drift Constitution II warns against.

## R10: Config schema for `tracker.kind: bindle`

**Decision**: Add `resolve_tracker_provider("bindle", settings, provider)` to `config/schema.ex`,
mirroring the existing `"local"` clause's shape (`config/schema.ex:525-534`): `repo_path` (the Bindle
repository root the CLI is invoked with `cd:`; see R15 for its default), a projection `path` override
(default resolved from `repo_path`, see R15 — not from `workflow_dir()` independently), `bindle_bin`
(default `"bindle"`, overridable for a non-`$PATH` install), and `owner_id_path` (default
`.symphony/bindle_owner_id`, relative to `workflow_dir()` — Symphony-owned state, deliberately not placed
inside the Bindle repository's own `.bindle-work/` directory).

**Rationale**: Matches the exact structural precedent every other adapter already uses for its own
provider-specific settings (Linear's `endpoint`/`api_key`/`assignee`, Local's `path`) — no new
configuration mechanism, just one more `resolve_tracker_provider/3` clause.

**Alternatives considered**: A dedicated top-level `bindle:` config section outside `tracker.provider` —
rejected: every other adapter's settings live inside `tracker.provider`; a separate section would break
FR-022's "distinct, explicit configuration choice" requirement's own consistency with how every other
tracker kind is already configured.

## R11: Test strategy for the SQLite and CLI boundaries

**Decision**: For projection tests, create a real temporary SQLite file per test with the exact
`task_projection` schema and `PRAGMA user_version = 1` (via `exqlite` directly in test setup), rather than
mocking the database boundary — this exercises the adapter's actual read-only-open and schema-validation
code paths, not a stand-in. For CLI tests, inject a `:bindle_cli_module` application-env override
(mirroring the already-existing `:gitlab_client_module` pattern, `gitlab/adapter.ex:47-48`) so orchestrator
integration tests can stub claim/release outcomes without requiring an installed `bindle` binary in CI or
local `mix test` runs; a small number of `bindle_cli_test.exs` unit tests exercise the real
`System.cmd/3`-based wrapper's argument construction and exit-code/output interpretation directly.

**Rationale**: Matches the repository's own stated preference (spec.md's Testing section, and the
project's general instruction to prefer real fixtures over mocking away architectural boundaries) while
keeping the test suite runnable without a developer-local Bindle install, consistent with how every other
hosted adapter (GitHub/GitLab/Jira/Linear/Asana) already tests its own HTTP boundary via an injectable
client module rather than live network calls.

**Alternatives considered**: Requiring a real installed `bindle` binary for CLI tests — rejected per the
task's own instruction not to make the suite depend on a developer-local Bindle binary absent an existing
clean convention for it (none exists in this repo today). Mocking the SQLite layer entirely — rejected:
the read-only-open and `PRAGMA user_version` behaviors are exactly the things worth verifying against a
real SQLite file, and `exqlite` against a small temp file is cheap.

## R12: Acquire-success / spawn-failure compensation (new)

**Decision**: In `Orchestrator.spawn_issue_on_worker_host/5`'s `{:error, reason} ->` branch (the case
where `Task.Supervisor.start_child/2` itself fails, orchestrator.ex:993-999), call `release_issue/2`
before calling the existing `schedule_issue_retry/4` — but only when `acquire_issue/2` was actually called
and succeeded for this dispatch attempt (i.e. only for a tracker whose adapter implements the callback
pair; a complete no-op otherwise, consistent with FR-005).

**Rationale**: Verified directly that today's spawn-failure branch schedules a retry with no release of
any kind (correct today, since no external claim exists to release for any current adapter). Once
`acquire_issue/2` (R6) runs immediately before this exact `Task.Supervisor.start_child/2` call, a spawn
failure after a successful acquisition leaves Symphony's own bookkeeping *not* marked as claimed
(`spawn_issue_on_worker_host/5`'s `{:error, reason}` branch never touches `state.claimed`), yet Bindle's
own claim row for that task now exists and is held by this owner. The scheduled retry will eventually call
`acquire_issue/2` again for the same task — which Bindle's own arbitration rejects, even from the same
owner, because the existing claim row's primary key already exists (`work_item_claims`'s `PRIMARY KEY
(work_item_id)`, `claim()`'s docstring: "of any number of concurrent attempts against the same item,
exactly one succeeds and every other fails immediately"). Without this compensation, that issue would
permanently deadlock against its own retry — never dispatched, and its Bindle claim never released except
by the next full startup's reconciliation sweep (R5), which is not an acceptable steady-state recovery
path for an ordinary transient spawn failure.

**Alternatives considered**: Marking the issue as `claimed` in `state.claimed` even on spawn failure, so
the existing retry-exhausted release path eventually fires — rejected: this misrepresents Symphony's own
in-memory state (the issue was never actually running) and would need its own new bookkeeping distinct
from every existing adapter's spawn-failure handling, a larger and less truthful change than releasing
immediately at the point of failure. Retrying the acquisition-then-spawn sequence as a single atomic unit
with automatic internal release-and-retry — rejected as unnecessary complexity; a single explicit release
call at the one point that needs it is the smaller change (Constitution II).

## R13: Release callback shape and single-call-site consolidation (new)

**Decision**: `release_issue/2` takes the issue's stable id and options — `release_issue(issue_id ::
String.t(), opts :: keyword())` — not a full `Tracker.Issue` struct. `acquire_issue/2` continues to take
the full candidate `Issue.t()`, since it is always genuinely available at its one call site. The
orchestrator's internal `release_issue_claim/2` helper becomes the single place `Tracker.release_issue/2`
is invoked; `terminate_running_issue/3`'s branch that finds a running entry is changed to delegate its
`claimed`/`blocked`/`retry_attempts` clearing to `release_issue_claim/2` (removing that branch's current
inline duplication of the same field-clearing `release_issue_claim/2` already performs) rather than having
`terminate_running_issue/3` also independently call `Tracker.release_issue/2` itself.

**Rationale**: Verified directly that `terminate_running_issue/3`'s three branches
(orchestrator.ex:554-579) have different data available: the `nil` branch and the catch-all branch already
delegate to `release_issue_claim(state, issue_id)` (only an id is available there — no `Issue` struct
exists to pass); the found-running-entry branch has a full `Issue` available (`running_entry`'s own
`:issue` key) but today duplicates `release_issue_claim/2`'s state-clearing logic inline instead of
calling it. `reconcile_blocked_issue_state/4` (orchestrator.ex:461,465,472) calls `release_issue_claim(state,
issue.id)` directly — an `Issue` is available at that call site, but only `issue.id` is actually passed
through today. Since at least one genuine release call site (the `nil`/catch-all branches of
`terminate_running_issue/3`) has only an id, not a full struct, an id-based callback is the smallest
truthful shape that fits every site without fabricating a partial `Issue` elsewhere (FR-020). Consolidating
every release path to call through `release_issue_claim/2` — rather than adding a second, independent
`Tracker.release_issue/2` call inside `terminate_running_issue/3`'s found-running-entry branch — is what
prevents the double-call risk this correction pass specifically flagged: if both `terminate_running_issue/3`
directly and `release_issue_claim/2` (which it currently doesn't call from that branch, but would need to
for consistency) each independently called `Tracker.release_issue/2`, a single logical termination event
would fire the external release call twice.

**Alternatives considered**: A full-`Issue`-based `release_issue/2` shape, reconstructing a partial `Issue`
struct (e.g. `%Issue{id: issue_id}`) at call sites where only an id is known — rejected per the task's own
instruction and FR-020: a struct with every field but `id` defaulted/nil is not a truthful representation
of anything, and nothing downstream needs those other fields for a release call. Leaving
`terminate_running_issue/3`'s found-running-entry branch's inline duplication in place and adding the
external release call there directly instead of consolidating into `release_issue_claim/2` — rejected:
this would require the *same* external-call logic to exist in two places (the direct call in
`terminate_running_issue/3`, and inside `release_issue_claim/2` for the other two branches and for
`reconcile_blocked_issue_state/4`'s direct calls), which is exactly the duplication that produces a
double-call bug if either copy is later touched without the other.

## R14: Fail-loud on structurally invalid projection rows (new)

**Decision**: The Bindle adapter validates each mapped row against Symphony's own minimum schedulable
shape (non-empty `id`/`identifier`/`title`/`status`, a parseable `created_at`) and returns a distinguishable
`{:error, _}` for the affected fetch if any row fails — it does not silently drop the malformed row and
return the rest as `{:ok, [...]}`.

**Rationale**: Verified directly that Bindle's own published schema makes `title` nullable
(`symphony_projection.py`'s `_CREATE_TASK_PROJECTION_SQL`: `title TEXT` with no `NOT NULL`, and
`ExternalProjectionRow.title: str | None`), while Symphony's existing `candidate_issue?/3`
(orchestrator.ex:870-871) requires `id`, `identifier`, `title`, and `state` all be non-empty binaries
before treating an issue as a dispatch candidate at all. A first-draft design proposed defensively
dropping a row that failed this shape check, mirroring `Local.Adapter.to_issue/1`'s existing defensive
style for its own file-backed format. For a Bindle-managed task, though, that would silently convert an
upstream `dispatchable: true` task into invisible, permanently unschedulable work with no operator-visible
signal that anything was wrong — effectively a second, undocumented admission filter living inside
Symphony's adapter, which FR-003 (verbatim passthrough, no synthesis) and `002-bindle-integration`'s own
"Symphony must not derive/recompute eligibility" framing (FR-003 there) both argue against. Failing loud
instead treats a missing-title task exactly like any other tracker/source failure (skip this poll tick,
surface the failure, retry next) — a Bindle-side data-quality issue an operator can actually notice and
fix upstream, rather than a task that silently never gets worked.

**Alternatives considered**: Dropping the malformed row silently (the first draft's choice, and
`Local.Adapter`'s own existing style) — rejected per the "second admission filter" and "invisible work"
reasoning above; `Local.Adapter`'s own defensive-drop precedent is for a same-repository, operator-owned
file format where a malformed row is far more likely to be genuine local corruption than a real upstream
work item worth surfacing — that precedent does not transfer cleanly to an externally-published,
upstream-owned artifact. Synthesizing a placeholder title (e.g. falling back to `identifier`) — rejected:
this is exactly the kind of synthesis FR-003 forbids, and would mask a genuine Bindle-side data-quality
signal rather than surfacing it.

## R15: `repo_path` default resolution (new)

**Decision**: `repo_path` defaults to `Config.workflow_dir()` (the directory containing the currently
active `WORKFLOW.md`) when not explicitly configured, and the projection artifact's default path is
resolved *relative to `repo_path`* (`<repo_path>/.bindle-work/symphony-projection.sqlite3`), not
independently relative to `workflow_dir()`. An explicit `repo_path` override remains supported.

**Rationale**: Verified directly (`elixir/README.md`'s setup instructions: "Copy this directory's
`WORKFLOW.md` to your repo") that `WORKFLOW.md`, and therefore `Config.workflow_dir()`, is conventionally
the root of the very repository Symphony is coordinating coding-agent work inside — for a Bindle-backed
deployment, that is ordinarily the same repository whose `.bindle-work/` directory holds the published
projection and whose root is the Bindle CLI's target `cd:`. A first-draft design required `repo_path` as
separately-configured, no-default state while defaulting the projection path relative to `workflow_dir()`
independently — those two defaults could silently diverge (an operator's `workflow_dir()` and their
configured `repo_path` pointing at two different repositories), letting the read side (projection) and
write side (CLI claim/release) accidentally target different Bindle repositories with no error. Deriving
the projection default from `repo_path` itself removes that divergence risk entirely, and defaulting
`repo_path` to `workflow_dir()` removes an otherwise-required, easy-to-get-wrong piece of configuration for
the common single-repository deployment case this fork actually targets.

**Alternatives considered**: Keeping `repo_path` as required, no-default configuration — rejected once the
common-case evidence above showed a safe, correct default exists; requiring configuration `002-bindle-
integration`'s own Constitution V ("avoid unnecessary abstraction"/unnecessary required configuration)
argues against when a correct default is available. Defaulting the projection path independently of
`repo_path` (the first draft's choice) — rejected per the accidental-divergence risk above.
