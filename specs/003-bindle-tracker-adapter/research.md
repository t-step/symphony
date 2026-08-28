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

**Second correction pass (2026-08-27, same day)**: R9 was rewritten and R16–R19 added after
`002-bindle-integration`'s own FR-013 correction (that spec's research.md R16: task `done` is a mechanical,
agent-triggerable execution fact, distinct from milestone `accepted`) and further Symphony-runtime grounding
found this feature's first correction pass had itself overcorrected or left gaps: (1) the first pass's
removal of any agent-invoked completion tool read `002-bindle-integration` User Story 5 more broadly than
its own corrected wording supports — R17 restores a narrowly-scoped one; (2) the acquisition call site and
`retry_candidate_issue?/2` re-validation, both shared between fresh dispatch and retry-continuation, were
never checked against Bindle's actual claim-uniqueness constraint for the retry-of-an-already-claimed-item
case — R16 fixes this; (3) R9's `routed_by_assignment` field was Linear-shaped by construction and did not
actually close Asana's own gap despite claiming to — rewritten below; (4) Bindle's `publish` mechanism was
never grounded — R18 does so and designs the restored tool's projection-refresh behavior; (5) the startup
reconciliation sweep's individual-failure retry liveness was never addressed — R19 fixes it using existing
scheduling infrastructure.

## R1: Read-only SQLite access to the published projection

**Decision**: Use the `exqlite` library (`~> 0.30`, resolving `0.40.0`), opening the projection via its
low-level `Exqlite.Sqlite3.open/2` with `mode: :readonly` (the `SQLITE_OPEN_READONLY` C flag, verified
against `exqlite`'s actual `Sqlite3.open/2` implementation — not a `file:<path>?mode=ro` URI string, which
`exqlite`'s API does not require) rather than a plain read-write connection.

**Correction (implementation-stage)**: this decision's original rationale claimed `exqlite` was "already
present in the project's dependency tree" — verified directly against `elixir/mix.exs`/`mix.lock` during
implementation that this was false; no SQLite library of any kind was present before this feature. `exqlite`
is added here as a new dependency. The decision to use it (over shelling out to `sqlite3`) remains correct
and is unaffected by this correction — it is simply the right library for the job, not a reuse of something
already vendored.

**Rationale**: `exqlite`'s low-level `Sqlite3` API satisfies FR-002's "opened exclusively via SQLite's own
read-only open mode" requirement directly via its `mode: :readonly` open flag. A plain-path connection
would open the file read-write by default and rely on the adapter simply "not issuing a write" —
insufficient per FR-002, which requires the connection itself be opened read-only.

**Alternatives considered**: Shelling out to the `sqlite3` CLI for reads — rejected: adds a second
external-process dependency (on top of the `bindle` CLI this feature already shells out to) for no benefit
when a proper read-only driver library is a single, well-maintained Hex dependency.

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

**Second-pass addition**: R6's call site (`spawn_issue_on_worker_host/5`, immediately before
`Task.Supervisor.start_child/2`) is reached by **both** a fresh dispatch and a continuation retry
(`handle_active_retry/4` → `do_dispatch_issue/4` → `spawn_issue_on_worker_host/5` — the identical function,
verified directly against `orchestrator.ex`'s actual control flow, not assumed). Calling `acquire_issue/2`
unconditionally at this shared site, as R6 originally described without qualification, is only correct for
the fresh-dispatch case — see R16 below for why an unconditional call here breaks the ordinary
crash-mid-run retry case R7 governs, and the fix (gate the call on `state.claimed` membership).

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

## R9: Per-adapter continuation-signal compatibility (rewritten, second correction pass — supersedes the original `routed_by_assignment` design)

**Original decision (historical, now superseded)**: Add a `routed_by_assignment: boolean()` field to
`Tracker.Issue`, populated only by Linear, and leave Asana unpopulated on the claim that its
`completed`-vs-section-name distinction was "a `state`/label concern already covered by the existing
label-match path."

**Why this was wrong**: That claim was never actually verified against Asana's code — it was an assumption.
Re-verified directly, second correction pass: `asana/client.ex`'s `normalize_issue/2` (lines 204–228) sets
`state` from `get_in(membership, ["section", "name"])` (line 207) — the task's Kanban-column/section name —
and sets `dispatchable` from `task["completed"] == false and task["resource_subtype"] != "section"` (line
223), two **independently fetched, independently computed** fields with no code anywhere tying them
together. Asana's own API lets a task's `completed` flag flip to `true` while its section membership (and
therefore `state`) stays exactly as it was — there is nothing in this adapter's code that would make
`state` change merely because `completed` did. This means the original R9's premise (label/state match
already catches this) is false: a task that completes without moving sections would, under the original
`routed_by_assignment`-only design, keep `routed?/2` returning `true` (label match unchanged, no assignment
field populated for Asana) even though it has genuinely completed — continuation would incorrectly persist.
Also, `routed_by_assignment`'s own name and default semantics ("no assignment concept, so assignment never
blocks continuation") are Linear-shaped by construction and do not generalize to a fact that isn't about
assignment at all.

**Decision**: Rename the field `continuation_allowed: boolean()` (default `true`, meaning "this adapter has
no independent continuation-revoking fact beyond label match, or the fact currently holds"), and populate it
for **two** adapters, not one:

- **Linear** (`linear/client.ex:496-499`): unchanged computation, `assigned_to_worker?(assignee,
  assignee_filter)` — Linear's existing still-assigned-to-this-worker check, previously folded silently into
  `dispatchable`, now surfaced as its own field with the same value.
- **Asana** (`asana/client.ex:223`): `task["completed"] == false`, independent of `resource_subtype` (which
  is a projection-membership concern, not a continuation one) and independent of `state`/section — this is
  the actual fix for the gap above: a task's continuation now correctly stops the moment `completed` flips
  to `true`, regardless of what its section name says.

`routed?/2` (R8) consults `continuation_allowed` in addition to label match, exactly as it would have
consulted `routed_by_assignment`. Every other adapter (Bindle, GitHub, GitLab, Jira, Local) leaves the field
at its default `true` — verified none of them has an independent, post-dispatch-relevant continuation-
revoking fact beyond ordinary terminal-state transition (GitHub: an issue cannot become a PR mid-run; GitLab/
Local: `dispatchable` is an unconditional constant; Jira: `dispatchable?/4`'s blocker-terminality half is
inert once dispatched, same reasoning as `002-bindle-integration` research.md R11; Bindle: `dispatchable`'s
only continuation-relevant behavior is the claim-induced flip R11/FR-017 already handles generically, and a
real terminal-state transition is already caught by `status` mapping straight onto `state`).

**Rationale**: A provider-neutral name and a verified-correct Asana population are both required for this
field to actually satisfy `002-bindle-integration` FR-017's per-adapter compatibility requirement, not just
appear to. Naming it after Linear's own mechanism (`routed_by_assignment`) while asserting-without-verifying
that Asana needs nothing is exactly the kind of unverified claim that produces a silent regression once a
real deployment hits it.

**Alternatives considered**: Computing each adapter's continuation-revoking check independently inside
`Orchestrator`/`AgentRunner` by comparing raw `Issue` fields (`assignee_id`, `state`) against configured
settings at continuation time — rejected: neither `assignee_id` nor `state` alone carries the adapter-specific
matching rule (Linear's own assignee-filter semantics, Asana's own `completed` flag, which isn't projected
onto any existing `Issue` field at all), and reimplementing per-adapter rules outside the adapter that
already computes them correctly risks exactly the kind of drift Constitution II warns against. Keeping
`routed_by_assignment`'s name but also populating it from Asana's `completed` flag — rejected: the field's
own documented semantics ("no assignment concept") would then be self-contradictory for Asana's population,
confusing to a future adapter author, and wrong to generalize from for a hypothetical future provider whose
continuation-revoking signal is neither assignment- nor Asana's-completion-shaped.

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

## R16: Fresh-admission vs. continuation-retry acquisition gating (new, second correction pass)

**Finding**: Traced directly against `orchestrator.ex`'s actual control flow (not assumed), the fresh-dispatch
path and the retry-continuation path converge on the same two functions: `refresh_issue_for_dispatch/1`
(which calls `revalidate_issue_for_dispatch/3`, which calls `retry_candidate_issue?/2`) and, immediately
after, `do_dispatch_issue/4` → `spawn_issue_on_worker_host/5` (R6's acquisition call site). Fresh dispatch
reaches them via `dispatch_issue/4`; retry-continuation reaches them via `handle_active_retry/4` — literally
the same functions, not merely structurally similar ones. `candidate_issue?/3` (the fresh-admission-only
predicate, gated on `dispatchable`) is used only in `should_dispatch_issue?/4`, never in the retry path;
`retry_candidate_issue?/2` is the retry path's own, separate re-validation predicate — but nothing in
today's code, or in this feature's first-draft design, gives `retry_candidate_issue?/2` different behavior
depending on whether the issue is a genuinely fresh admission (e.g., following R12's spawn-failure
compensation release) or a continuation of an issue Symphony already holds a claim for (an ordinary
crash-mid-run retry, R7).

This matters once `acquire_issue/2` exists: for a continuation retry, Symphony's claim is still held (R7 —
`release_issue/2` is deliberately not called for this case), so the Bindle projection reports `dispatchable:
false` for that task (data-model.md §2). If `retry_candidate_issue?/2` still requires `dispatchable = true`
(as it effectively does today, sharing logic with the admission predicate), the retry is rejected before it
ever reaches the acquisition call site — a real regression this feature's admission/continuation split
(FR-013–FR-015) does not, by itself, fix, because `retry_candidate_issue?/2`'s re-validation is a distinct
code path from `Orchestrator.reconcile_issue_state/4`'s continuation check. Even supposing re-validation were
fixed, the acquisition call site itself (`spawn_issue_on_worker_host/5`) would then call `acquire_issue/2`
unconditionally — and Bindle's `work_item_claims` primary key is `work_item_id` alone (verified,
`work_ledger.py:1163-1169`), so a second `claim()` against a task this same owner already holds is rejected
(`already_claimed`), not a no-op. Either failure mode permanently starves the retry.

**Decision**: Both the re-validation predicate and the acquisition call site MUST branch on whether the issue
is already present in `state.claimed`:

- **Fresh admission** (issue not in `state.claimed`): re-validation requires `dispatchable = true` exactly as
  today; `spawn_issue_on_worker_host/5` calls `acquire_issue/2` and only proceeds to spawn on success — R6's
  original description, unchanged for this mode.
- **Continuation retry** (issue already in `state.claimed`, because a prior worker for it actually started):
  re-validation MUST NOT require `dispatchable = true` — it uses only the continuation/routing concern
  (`routed?/2`, FR-013) plus the existing terminal/active/missing-from-tracker checks, the same ones ordinary
  reconciliation (FR-014/FR-015) already uses. `spawn_issue_on_worker_host/5` MUST NOT call `acquire_issue/2`
  for this mode — it proceeds directly to `Task.Supervisor.start_child/2`, reusing the already-held claim.

This composes correctly with R12's spawn-failure compensation: since that compensation releases the claim
and never sets `state.claimed` (`spawn_issue_on_worker_host/5`'s `{:error, reason}` branch never touches
`state.claimed`, verified directly), the resulting retry is naturally a fresh-admission retry under this
same `state.claimed`-membership test — no separate signal is needed to distinguish it from an ordinary
crash-mid-run retry.

**Rationale**: This is the same category of correction as `002-bindle-integration` research.md R11 — a
genuine, verified defect that only manifests once a durable-claim-aware tracker (Bindle) makes a retry's
own re-admission interact with Symphony's own held claim state, discovered by tracing actual control flow
rather than assuming the fresh/retry distinction FR-016 already drew for `candidate_issue?/3` automatically
extends to `retry_candidate_issue?/2` and the acquisition call site. `state.claimed` membership is the
correct, already-available signal to branch on — it already means exactly "a prior worker for this issue
actually started," which is precisely fresh-admission-vs-continuation's real distinction.

**Alternatives considered**: Adding a new, separate boolean/flag threaded through the retry scheduling
message to mark "this retry already holds a claim" — rejected: `state.claimed` already carries exactly this
fact; a parallel flag would be new state duplicating an existing one, the kind of unnecessary abstraction
Constitution V warns against. Always calling `acquire_issue/2` and treating `already_claimed` as a
recoverable, non-fatal result meaning "proceed anyway" — rejected: this would make the orchestrator
silently paper over a failed acquisition call by assuming a specific error reason means "it's fine, it's
mine," which is fragile (it can't actually distinguish "already claimed by me" from "already claimed by a
different, unrelated owner" without a further round-trip) and unnecessary when the branch can be made
correctly up front using state Symphony already has.

## R17: Restoring the agent-invoked task-completion tool (new, second correction pass)

**Finding**: This feature's first correction pass removed the first draft's `done`-tool design entirely,
reasoning from `002-bindle-integration` User Study 5's then-current wording ("semantic completion... MUST
remain human-resolved") that any agent-invoked completion capability crossed that boundary. `002-bindle-
integration`'s own second correction pass (that spec's research.md R16) found this reading overbroad:
Bindle's actual model (`specs/002-milestone-task-work-items/spec.md`, `docs/DECISIONS.md` D038) draws a hard
line between `type = 'task'` reaching `done` (mechanical, explicitly not a human-review event) and
`type = 'milestone'` reaching `accepted` (the actual semantic judgment) — and `002-bindle-integration` FR-013
now explicitly authorizes an agent's own bound-task `done` request through the existing FR-009 tracker-write
boundary. This feature's removal of the tool was therefore not required by the (corrected) architecture
contract; it was an overcorrection based on the contract's own prior overbroad wording.

**Decision**: Restore one narrow, agent-invoked tool, `SymphonyElixir.Bindle.AgentTool`, exposed through the
Bindle adapter's `agent_tool_specs/0`/`execute_agent_tool/3` implementation (spec.md FR-025/FR-026):

- Exactly one tool, marking the session's own bound Bindle task `done`.
- The target task id is resolved exclusively from `opts[:issue].id` — the session-bound `Tracker.Issue`
  `SymphonyElixir.ClaudeCode.MCPServer` fixes at `start_link/1` time and passes into every
  `execute_agent_tool/3` call, verified directly (`claude_code/mcp_server.ex:54,59,163-171`) to be the one
  and only source of the current session's issue, never read from a model-supplied tool argument. This
  mirrors `local_tracker_set_state`'s existing scope-restriction pattern exactly.
- Implementation calls `SymphonyElixir.Bindle.Cli.done/3` (`bindle work done <id>`, no `--owner` argument —
  R4's owner identity is not used here, since Bindle's `done` write surface has no ownership/claim
  requirement, verified `contracts/task-write-surface.md`), then, on success, `Cli.publish/2` (R18).
- No milestone, evidence, or dependency-graph operation is exposed, wrapped, or reachable from this tool —
  it has exactly one code path, and that path only ever constructs a `bindle work done`/`publish` command
  line for the one session-bound task id.

**Rationale**: This restores real, demonstrated value (an agent's own bound task completion becoming visible
to Bindle, and eventually to any human reviewing milestone readiness) without reopening any part of
`002-bindle-integration`'s boundary this feature's first correction pass correctly protected — milestone
acceptance, evidence, dependency/blocking reconstruction, and any orchestrator-owned lifecycle-write API
remain exactly as forbidden as the first correction pass left them (FR-018/FR-019/FR-023). The tool's session-
only scoping is what makes it safe to restore: it cannot be pointed at any task beyond the one Symphony
itself bound the session to, so a coding agent's tool-call arguments (which an untrusted model process
ultimately generates) have no path to naming an arbitrary target.

**Alternatives considered**: Leaving the tool removed and treating agent-triggered task completion as
permanently out of scope — rejected: this was the first correction pass's position, now shown to rest on an
overbroad reading of a since-corrected upstream contract; leaving it removed would mean this feature
implements a stricter rule than `002-bindle-integration` itself now requires, for no benefit. Allowing the
tool to accept a model-supplied task id (with server-side validation that it matches the session's bound
issue) — rejected: strictly more code and a strictly larger attack surface than simply never reading a
model-supplied id in the first place; the session-bound `opts[:issue]` is already authoritative and
sufficient.

## R18: Projection refresh after agent-triggered `done` (new, second correction pass)

**Finding**: Bindle's `bindle work publish` (verified `src/bindle/cli.py`, `symphony_projection.py`) is a
fully separate, manually-triggered command that regenerates the published `task_projection` table in one
atomic transaction. None of `bindle work done`/`claim`/`release`'s CLI subcommand implementations call
`publish()` internally, and `done`'s `argparse` subparser accepts no `--publish` flag or equivalent hook —
confirmed by direct inspection finding no cross-call between the `_cmd_work_*` handlers and `publish()`.
This means that, absent this feature doing something about it, a task an agent marks `done` via R17's tool
would leave the published projection reporting that task's stale prior `status` until *some* future
`bindle work publish` happens to run — which, on Bindle's current design, requires an external, undocumented
manual step, exactly the gap the task's own instructions flagged as load-bearing once R17's tool exists.

Separately, claim/release correctness does **not** depend on the projection's freshness at all: Bindle's
claim arbitration is a durable, atomic `INSERT`/`DELETE` against `work_item_claims`, entirely independent of
`generate_external_projection()`'s own read path (verified: neither `claim()` nor `release_claim()` touches
the projection artifact or calls `publish()`). The projection's staleness only affects what an *external*
reader (Symphony's own polling, or a human/dashboard) currently sees — never whether a concurrent claim
attempt is correctly arbitrated.

**Decision**: Only the task-completion tool (R17) triggers a publish, immediately after a successful `done`:
`SymphonyElixir.Bindle.Cli.publish/2` invokes `bindle work publish` (also no `--owner` argument — verified
`publish` takes none either) right after `done/3` returns success. The orchestrator-owned claim/release seam
(`acquire_issue/2`/`release_issue/2`) does **not** call `publish` — there is no demonstrated correctness need
for one, per the independence finding above, and adding one at every claim/release would be an unjustified
subprocess-call addition (Constitution V) with no requirement behind it.

**Failure semantics**: if `done` succeeds and the subsequent `publish` fails, the tool's result MUST
distinguish the two: the `done` transition is authoritative and already succeeded in Bindle's own ledger —
it MUST NOT be retried, because Bindle's `mark_done()` guard (`status = 'open'`) would reject a second call
with `not_open`, a confusing, spurious failure for a mutation that already genuinely succeeded (this is
*not* the same as `claim`'s idempotent-safe-reject semantics being harmless to retry — retrying `done` here
would misreport a real success as a failure). The `publish` failure is logged and surfaced distinctly (e.g.
as part of the tool's own result payload, not folded into an overall failure) — this feature does not add
automatic retry-until-success `publish` logic beyond this one best-effort attempt; a projection that
remains stale until the next successful publish (an operator's own `bindle work publish` cadence, or this
same task's own next Symphony-initiated mutation, if any) is an accepted, explicitly-documented limitation.

**Rationale**: This is the smallest mechanism that makes the task's own guidance ("after a successful
Symphony-initiated Bindle lifecycle mutation such as `done`, invoke Bindle's own supported `bindle work
publish` command") concrete against Bindle's actual, verified CLI contract, while explicitly declining to
extend the same treatment to claim/release, where grounding shows it would add cost without a correctness
benefit.

**Alternatives considered**: Publishing after every claim/release as well, for symmetry — rejected per the
independence finding above; symmetry is not itself a requirement when the two writes have genuinely
different correctness dependencies on projection freshness. Retrying `done` if `publish` fails, treating the
pair as one logical transaction — rejected: `done` and `publish` are not atomic together on Bindle's side (no
such combined operation exists), and retrying `done` specifically would produce a spurious `not_open`
failure for what is actually a fully successful task completion, misleading whoever reads the result.
Adding a bounded retry loop around `publish` itself — rejected as unnecessary scope beyond what the task's
own instructions asked to investigate; a single best-effort attempt with distinct failure surfacing is the
smallest mechanism satisfying the visibility goal without inventing new retry infrastructure this feature
has no other need for.

## R19: Startup-reconciliation liveness — bounded per-id retry using existing scheduling infrastructure (new, second correction pass)

**Finding**: The corrected startup-time reconciliation sweep (data-model.md §6, R5) enumerates every
projected task id and attempts an owner-scoped release for each, continuing past an individual failure
rather than aborting the whole sweep. This correctly avoids blocking recovery of *other*, healthy tasks on
one bad release — but, as originally described, a task whose release failed (e.g. a transient `bindle` CLI
hiccup at that exact moment) would receive no further attempt until the next full Symphony process restart,
which the task's own instructions correctly flag as an unacceptable "recovered without manual intervention"
claim if that is the only retry path.

**Decision (chosen shape: bounded retry, not fail-startup)**: Reuse the orchestrator's existing issue-retry
timer/backoff primitive (`schedule_issue_retry/4`'s underlying scheduling mechanism) rather than building a
new one. For any id whose release fails during the initial sweep, schedule a small, bounded number of
follow-up release-only retry attempts for exactly that id (not the whole sweep), using the same timer
primitive. Normal polling begins immediately after the initial sweep pass completes, regardless of whether
any individual release is still pending a follow-up retry — an unrecovered stale claim for one task must
not block dispatch of every other, unrelated dispatchable task. If the bounded retry budget is exhausted
without success, log a persistent, operator-visible failure naming the specific task id; do not silently
drop it, and do not claim it was recovered.

**Rationale (why bounded retry over "fail startup entirely")**: The task's own instructions offer two
shapes: fail startup if any release fails (so polling never begins with a known-unrecovered claim), or a
bounded retry. Failing startup entirely was rejected because it makes the *entire deployment's* liveness
hostage to a single stale claim or a single transient `bindle` CLI failure — a Symphony process that cannot
start at all provides zero service for every other, unrelated dispatchable task, which is a worse outcome
than the narrower one (a single task's claim staying stuck a little longer while everything else proceeds
normally). A bounded retry reusing existing infrastructure recovers the common case (a transient failure)
without an operator restart, while still surfacing a persistent, operator-visible failure — not silently
declared solved — if the bound is exhausted, honestly documenting the residual gap (a specific stuck claim
that then needs a manual `bindle work release`/operator restart) rather than either hiding it or blocking
the whole deployment on it.

**Explicitly accepted trade-off**: A small window remains where a specific task's stale claim needs manual
intervention if the bounded retry budget is exhausted — this feature does not claim otherwise. This is
judged the better trade-off than either silently leaving it unretried until restart (the original gap) or
blocking all polling on it (the fail-startup alternative), and is surfaced loudly (persistent log entry
naming the task id) rather than assumed away.

**Alternatives considered**: Fail startup entirely on any release failure — rejected per the liveness
reasoning above. A new, dedicated retry-scheduling mechanism for stale-claim releases, separate from
`schedule_issue_retry/4`'s existing primitive — rejected: unnecessary duplication (Constitution V) when the
existing timer/backoff mechanism already does exactly what's needed (schedule a bounded, backed-off retry
for one identified unit of work). Reintroducing a local claims ledger to track "still needs retry" state
across restarts — rejected: explicitly out of scope per R5's own crash-unsafety finding and this feature's
Assumptions; the bounded retry here is in-memory, scoped to the current process's own startup sequence, and
does not need to survive a further restart (a further restart simply re-runs the full sweep from scratch,
which is already safe per R5).
