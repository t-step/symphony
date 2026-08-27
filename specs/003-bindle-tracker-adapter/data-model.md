# Phase 1 Data Model: Bindle-Backed Tracker Adapter Implementation

## 1. Bindle Projection Row → `Tracker.Issue` mapping

Source: `task_projection` table in the externally-published `symphony-projection.sqlite3`
(`PRAGMA user_version = 1`, verified against Bindle's actual publisher):

| Projection column         | Type    | Nullable | `Tracker.Issue` field | Mapping rule                                   |
|----------------------------|---------|----------|------------------------|-------------------------------------------------|
| `id`                       | TEXT    | NO (PK)  | `id`                   | Verbatim                                         |
| `identifier`                | TEXT    | NO       | `identifier`           | Verbatim                                         |
| `title`                    | TEXT    | YES      | `title`                | Verbatim (`nil` passes through if absent)        |
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

**Validation rule**: `id`, `identifier`, and `status` MUST be present and non-empty for a row to be mapped
at all (mirrors `candidate_issue?/3`'s existing `present_string?` guard for `id`/`identifier`/`title`/
`state`) — a row missing any of these is dropped from the returned list rather than raising, consistent
with existing adapters' defensive mapping style (e.g. `Local.Adapter.to_issue/1`).

## 2. Projection Artifact (read, not owned, by this feature)

- **Path**: operator-configured `tracker.provider["path"]`, default
  `.bindle-work/symphony-projection.sqlite3`, resolved relative to `Config.workflow_dir()` — same
  resolution rule `Local.Adapter.resolve_provider_path/2` already uses for its own `path` key.
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

- **`dispatchable?/1`** — `issue.dispatchable` alone. Admission concern only (FR-003/FR-012).
- **`routed?/2`** — `label_match?(issue.labels, required_labels) and issue.routed_by_assignment`.
  Continuation/routing concern only (FR-012).
- **`routable?/2`** (kept, now composed) — `dispatchable?(issue) and routed?(issue, required_labels)`.
  Used only by `candidate_issue?/3` (the legitimate admission-path caller, unchanged, FR-015).

## 5. Owner Identity

- **Shape**: an opaque string, generated via `:crypto.strong_rand_bytes/1` + hex/base encoding (same class
  of generation Symphony already uses elsewhere for opaque ids — no new crypto primitive introduced) on
  first use, then persisted verbatim.
- **Storage**: a plain-text file at `tracker.provider["owner_id_path"]`, default
  `.symphony/bindle_owner_id`, resolved relative to `Config.workflow_dir()`. Not a database row — this is
  the smallest mechanism that satisfies "persist across restarts" (FR-010) without a new storage engine
  (Constitution V).
- **Lifecycle**: read on every `acquire_issue/2`/`release_issue/2`/startup-reconciliation call; if the file
  does not exist, generate a new value and write it once, then reuse. Never regenerated once written
  (regenerating would orphan any Bindle-side claims already made under the old identity, defeating R5's
  reconciliation).

## 6. Local Claims Ledger (crash-recovery state, new)

- **Shape**: a small JSON object, `%{issue_id => %{"claimed_at" => iso8601_string}}`, one entry per
  currently-held Bindle claim this deployment believes it holds.
- **Storage**: `tracker.provider["claims_ledger_path"]`, default `.symphony/bindle_claims.json`, resolved
  relative to `Config.workflow_dir()`.
- **Writes**:
  - `acquire_issue/2` success → add an entry.
  - `release_issue/2` (R7: regardless of the underlying CLI call's own success/failure) → remove the
    entry.
  - Startup-time reconciliation (R5) → for every remaining entry, call `bindle work release`, then remove
    the entry regardless of that call's outcome (a failed release here is logged; the entry does not
    perpetually block startup, since Bindle-side claim staleness is Bindle's own concern once release has
    been attempted).
- **Not a source of truth for anything Bindle-owned**: this ledger only ever answers "what did *this*
  Symphony instance most recently believe it claimed," purely to know what to attempt to release on
  startup — it is never consulted to decide dispatch eligibility (that remains the projection's
  `dispatchable` fact, FR-003) and never treated as authoritative over Bindle's own claim state.

## 7. Config schema additions (`tracker.provider` for `tracker.kind: bindle`)

| Key                   | Required | Default                                   | Meaning                                             |
|------------------------|----------|--------------------------------------------|------------------------------------------------------|
| `path`                | No       | `.bindle-work/symphony-projection.sqlite3` | Projection artifact path (relative to `workflow_dir`) |
| `repo_path`           | **Yes**  | none                                        | Bindle repository root; `bindle` CLI is invoked with `cd:` set to this |
| `bindle_bin`          | No       | `"bindle"`                                  | CLI binary name/path (for a non-`$PATH` install)     |
| `owner_id_path`       | No       | `.symphony/bindle_owner_id`                 | Owner-identity persistence path                       |
| `claims_ledger_path`  | No       | `.symphony/bindle_claims.json`              | Local claims-ledger path                              |

`validate_config/1` (FR-002/existing `Tracker.validate_config/1` seam) MUST reject configuration missing
`repo_path` and MUST attempt to open-and-validate the resolved projection path (schema-version check),
surfacing a clear, distinguishable error for a misconfigured deployment before it starts polling —
mirroring `Local.Adapter.validate_config/1`'s existing `validate_provider_path/1` pattern.
