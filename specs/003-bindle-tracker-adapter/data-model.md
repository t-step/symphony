# Phase 1 Data Model: Bindle-Backed Tracker Adapter Implementation

**Correction pass (2026-08-27)**: §5 (Owner Identity), §6 (was "Local Claims Ledger," now "Startup
Reconciliation"), §7 (config defaults), and §1's row-validation rule were revised; see `research.md`
R4/R5/R14/R15 for the full grounding. A local claims ledger is no longer part of this design.

## 1. Bindle Projection Row → `Tracker.Issue` mapping

Source: `task_projection` table in the externally-published `symphony-projection.sqlite3`
(`PRAGMA user_version = 1`, verified against Bindle's actual publisher):

| Projection column         | Type    | Nullable | `Tracker.Issue` field | Mapping rule                                   |
|----------------------------|---------|----------|------------------------|-------------------------------------------------|
| `id`                       | TEXT    | NO (PK)  | `id`                   | Verbatim                                         |
| `identifier`                | TEXT    | NO       | `identifier`           | Verbatim                                         |
| `title`                    | TEXT    | YES      | `title`                | Verbatim — but see validation rule below         |
| `description`              | TEXT    | YES      | `description`          | Verbatim                                         |
| `status`                   | TEXT    | NO       | `state`                | Verbatim passthrough — no synthesis              |
| `dispatchable`              | INTEGER | NO (0/1) | `dispatchable`         | `1 -> true`, `0 -> false`                        |
| `created_at`                | TEXT    | NO       | `created_at`           | Parsed as `DateTime` (ISO-8601, same parser convention as `Local.Adapter`'s `parse_datetime/1`) |

Every other `Tracker.Issue` field (`native_ref`, `priority`, `branch_name`, `url`, `assignee_id`, `labels`,
`blocked_by`, `updated_at`, `routed_by_assignment`) is left at its existing struct default — the
projection publishes none of them, and none of them gate any admission/continuation decision for this
adapter. `routed_by_assignment` defaults to `true` (§3 below): the Bindle adapter has no assignment
concept, so routing for a Bindle-managed issue is governed by label match alone, same as every adapter
that does not populate this field.

**Validation rule (fail-loud, not defensive-drop)**: Symphony's own `candidate_issue?/3` requires
`id`/`identifier`/`title`/`state` all be non-empty binaries before treating an issue as a dispatch
candidate. Bindle's `title` column is genuinely nullable (verified:
`symphony_projection.py`'s `_CREATE_TASK_PROJECTION_SQL` has no `NOT NULL` on `title`;
`ExternalProjectionRow.title: str | None`). If any row fails this minimum-shape check (missing/empty
`id`, `identifier`, `title`, or `status`, or an unparseable `created_at`), the fetch as a whole MUST
return a distinguishable `{:error, _}` — **not** silently drop that one row and return the rest as a
successful, shorter list. `{:ok, []}` is reserved for a genuinely empty query result. Silently dropping a
malformed row would convert an upstream `dispatchable: true` task into invisible, permanently
unschedulable work with no operator-visible signal — effectively a second, undocumented admission filter
inside Symphony (research.md R14).

## 2. Projection Artifact (read, not owned, by this feature)

- **Path**: resolved from `repo_path` (§7) by default — `<repo_path>/.bindle-work/symphony-projection.sqlite3`
  — with an explicit `tracker.provider["path"]` override supported for a deployment where the projection
  genuinely lives elsewhere. Deriving the default from `repo_path` (rather than independently from
  `Config.workflow_dir()`) prevents the read side and write side from silently targeting different Bindle
  repositories (research.md R15).
- **Open mode**: read-only URI connection only (R1). No write, migration, or repair statement is ever
  issued against it.
- **Schema-version gate**: `PRAGMA user_version` MUST equal `1`; any other value, or any failure to open
  or query the file, produces `{:error, _}` before any row is read (R2).
- **Ownership**: entirely Bindle's — this feature never creates this file, never assumes it exists at
  startup (a `tracker.kind: bindle` deployment whose Bindle repo has never published one is simply an
  "unreadable projection" failure, same as any other missing/misconfigured tracker source).

## 3. `Tracker.Issue` struct change

New field: `routed_by_assignment: boolean()`, default `true`.

- **Semantics**: whether this issue's tracker adapter has an assignment concept that can independently
  revoke routing (continuation eligibility) — `true` means "no such concept, or currently still assigned,"
  `false` means "this adapter tracks assignment and this issue is no longer assigned to this worker."
  Defaulting to `true` means every adapter that does not populate this field is unaffected (R9).
- **Populated by**: Linear's client only (`linear/client.ex`), computed from the exact same
  `assigned_to_worker?(assignee, assignee_filter)` check it already performs internally to derive
  `dispatchable` today (R9) — no new Linear-side computation, just surfacing an existing one as its own
  field instead of folding it silently into `dispatchable`.
- **Not populated by**: Bindle, GitHub, GitLab, Jira, Local, Memory (no assignment-revocation concept for
  any of these as of this feature; Asana's `completed`/section-name concern is a `state` matter, not an
  assignment matter — confirmed by reading `asana/client.ex`, where `dispatchable` derives only from
  `task["completed"]`/`resource_subtype`, no assignee involvement).

## 4. `Tracker.Issue` predicate split

Replaces the single `routable?/2`:

- **`dispatchable?/1`** — `issue.dispatchable` alone. Admission concern only (FR-003/FR-013).
- **`routed?/2`** — `label_match?(issue.labels, required_labels) and issue.routed_by_assignment`.
  Continuation/routing concern only (FR-013).
- **`routable?/2`** (kept, now composed) — `dispatchable?(issue) and routed?(issue, required_labels)`.
  Used only by `candidate_issue?/3` (the legitimate admission-path caller, unchanged, FR-016).

## 5. Owner Identity (revised)

- **Shape**: an opaque string, generated via `:crypto.strong_rand_bytes/1` + hex/base encoding (same class
  of generation Symphony already uses elsewhere for opaque ids — no new crypto primitive introduced) on
  first use, then persisted verbatim.
- **Storage**: a plain-text file at `tracker.provider["owner_id_path"]`, default
  `.symphony/bindle_owner_id`, resolved relative to `Config.workflow_dir()` (Symphony-owned deployment
  state — deliberately *not* placed inside the Bindle repository's own `.bindle-work/` directory, which is
  Bindle-owned and only ever written by Bindle itself).
- **Lifecycle**: read on every `acquire_issue/2`/`release_issue/2` call and by startup-time reconciliation
  (§6). If the file does not exist, generate a new value and write it once, then reuse. **If the file
  exists but its contents are corrupt or empty, initialization MUST fail loud** (a startup/configuration
  error) rather than silently generating a replacement — regenerating would orphan any Bindle-side claims
  already made under the original identity, with no local record connecting the two, and would defeat §6's
  recovery mechanism, which depends on reusing the same identity a prior run's claims were made under.
- **Single-active-process assumption**: this design assumes exactly one Symphony process is actively using
  one persisted owner identity against one Bindle repository at a time (spec.md Out of Scope). Coordinating
  multiple concurrently-running Symphony processes sharing one owner identity is out of scope for this
  feature.

## 6. Startup Reconciliation (replaces the first draft's "Local Claims Ledger")

**There is no local claims ledger in this design.** A first-draft design persisted a local JSON ledger of
"claims this deployment believes it holds," but that design cannot actually recover the one failure mode
it exists for: a Bindle claim can succeed and the process can die before the local ledger entry is even
written, leaving a stale claim with no local record of it (research.md R5).

Instead, on Symphony startup, before the orchestrator begins normal polling, if `tracker.kind: bindle` is
active:

1. Read the current Bindle-facing projection (§2) — the same reader User Story 1's adapter uses.
2. Enumerate every task `id` it currently lists (regardless of that task's `dispatchable` value — a
   claimed task still appears, only its `dispatchable` fact differs).
3. For each `id`, call `bindle work release <id> --owner <persisted-owner>` (§5's owner identity).

**Why this is safe and sufficient without a local ledger**: `release_claim`'s own contract is a safe
no-op for a task not claimed by the given owner, including an already-unclaimed task (`work_ledger.py`,
`release_claim/2`'s docstring). Every non-archived task Symphony could ever have claimed necessarily still
appears in the current projection if it remains live (`generate_external_projection()`'s structural
`WHERE archived_at IS NULL AND type = 'task'` predicate is independent of claim state); if it has since
been archived, Bindle itself removes any lingering claim row on archival. So a blind, projection-wide,
owner-scoped release sweep recovers any stale claim this deployment could hold, with zero local state to
keep synchronized and nothing to lose in a crash.

**Failure mode**: if the projection cannot be read or fails its schema-version check (§2) at this moment,
reconciliation MUST surface the same distinguishable tracker/source failure an ordinary poll failure would
produce — it MUST NOT silently skip recovery, and MUST NOT silently proceed as though nothing needed
releasing.

## 7. Config schema additions (`tracker.provider` for `tracker.kind: bindle`)

| Key                   | Required | Default                                              | Meaning                                             |
|------------------------|----------|--------------------------------------------------------|--------------------------------------------------------|
| `repo_path`           | No       | `Config.workflow_dir()`                                 | Bindle repository root; `bindle` CLI is invoked with `cd:` set to this (research.md R15) |
| `path`                | No       | `<repo_path>/.bindle-work/symphony-projection.sqlite3`  | Projection artifact path, resolved relative to `repo_path` (not independently relative to `workflow_dir()`) |
| `bindle_bin`          | No       | `"bindle"`                                              | CLI binary name/path (for a non-`$PATH` install)       |
| `owner_id_path`       | No       | `.symphony/bindle_owner_id`                             | Owner-identity persistence path, relative to `Config.workflow_dir()` (Symphony-owned state, independent of `repo_path`) |

**Revision note**: the first-draft table required `repo_path` with no default and defaulted `path`
independently relative to `workflow_dir()` — that combination could let the read side (projection) and
write side (CLI `cd:`) silently target two different repositories. This table also drops the first
draft's `claims_ledger_path` entry entirely (§6 removes the local ledger).

`validate_config/1` (FR-002/existing `Tracker.validate_config/1` seam) MUST attempt to open-and-validate
the resolved projection path (schema-version check), surfacing a clear, distinguishable error for a
misconfigured deployment before it starts polling — mirroring `Local.Adapter.validate_config/1`'s existing
validate-then-delegate pattern. Because `repo_path` now has a default, `validate_config/1` no longer needs
to reject a missing `repo_path` as a distinct error case; an operator-supplied empty-string override, if
one is explicitly given, is still rejected.

## 8. Acquisition/Release Seam call shapes and single-call-site rule

- **`acquire_issue(Issue.t(), keyword())`** — takes the full candidate `Issue`, genuinely available at its
  one call site (`Orchestrator.spawn_issue_on_worker_host/5`, immediately before
  `Task.Supervisor.start_child/2`). Calls `bindle work claim <id> --owner <owner>` with **no**
  `--worktree`/`--branch` argument (research.md R6 — supplying `Workspace.workspace_key/1` as `--worktree`
  would be misinterpreted by Bindle's own reconciliation as a real, checkable filesystem/Git-worktree
  path, producing false `stale_claim` findings).
- **`release_issue(issue_id :: String.t(), keyword())`** — takes only the issue's stable id, not a full
  `Issue` struct (research.md R13): at least one genuine release call site
  (`terminate_running_issue/3`'s `nil`/catch-all branches) has only an id available, and this feature MUST
  NOT fabricate a partial `Issue` merely to satisfy a symmetric callback shape.
- **Single external call per logical release event**: `Tracker.release_issue/2` MUST be invoked from
  exactly one place in the orchestrator's own logic — `release_issue_claim/2` — reached by every release
  path: `terminate_running_issue/3`'s three branches (its found-running-entry branch is changed to
  delegate its state-clearing to `release_issue_claim/2` instead of duplicating it inline, so it also
  goes through the one call site) and `reconcile_blocked_issue_state/4`'s three direct calls. This
  prevents a single logical termination/release event from firing the external `bindle work release` call
  twice.

## 9. Acquire-success / spawn-failure compensation

New behavior at `Orchestrator.spawn_issue_on_worker_host/5`'s `{:error, reason} ->` branch (today: logs
and calls `schedule_issue_retry/4` with no release of any kind, correct today since no adapter implements
`acquire_issue/2`): once `acquire_issue/2` runs immediately before this same `Task.Supervisor.start_child/2`
call, this branch MUST call `release_issue/2` (via `release_issue_claim/2`, §8) **before** calling
`schedule_issue_retry/4` — but only for a dispatch attempt where acquisition was actually performed.

**Why this differs from the ordinary retry case**: a worker that already started and crashed mid-run is
retried by reusing its existing workspace/branch and its existing Bindle claim (FR-007) — nothing is
released. A worker that never started at all (spawn itself failed) has no workspace/attempt to reuse; its
Bindle claim, if not released, would cause the scheduled retry's own next `acquire_issue/2` call to be
rejected by Bindle as already-claimed by this same owner — a self-inflicted deadlock (research.md R12).
