# Contract: Local Work-Tracking Source (`tracker.kind: local`)

Follows the exact adapter-profile documentation shape `SPEC.md` §11.2 already requires of every tracker
adapter ("Each adapter MUST publish a compact profile ... exact supported `tracker.kind` value; exact
`tracker.provider` keys ...").

## `tracker.kind`

`"local"`.

## `tracker.provider` keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `path` | string | `.symphony/local_tracker.json` | Resolved relative to the directory containing the active `WORKFLOW.md`, same rule as `workspace.root` (`Config.local_workspace_root/0`). `~` and `$VAR` expansion apply per `SPEC.md` §6.1. |

No secret keys — `secret_environment_names/1` always returns `[]` (data-model.md §2).

## `tracker.active_states` / `tracker.terminal_states`

Same override mechanism as every adapter. Defaults (mirroring the existing `"linear"`/`"memory"`
fallback branch in `Config.Schema.finalize_settings/1`):

- `active_states` default: `["todo", "in_progress", "blocked"]`
- `terminal_states` default: `["done", "cancelled"]`

## `fetch_issues_by_states/1`

Reads the store (R2: absent path → initialize fresh empty store and return `{:ok, []}`; present-but-corrupt
→ `{:error, {:local_tracker_corrupt, reason}}`), returns every `IssueRecord` whose normalized `state`
matches one of the requested (normalized) state names, mapped 1:1 to `Tracker.Issue.t()`. Empty
`state_names` returns `{:ok, []}` without touching the file, per §11.1.

## `fetch_issues_by_ids/1`

Same read/corruption behavior; returns the subset of records whose `id` is in the requested set. IDs not
present in the store are omitted (never synthesized), matching §11.1's "omission means no longer
visible" rule. Empty `issue_ids` returns `{:ok, []}` without touching the file.

## `validate_config/1`

- `path`'s parent directory must be creatable/writable (validated the same class of check
  `PathSafety`/`Workspace` already performs for `workspace.root`).
- No provider-side network/auth to validate (unlike GitHub/GitLab/Jira/Linear), so this is a filesystem
  reachability check only, run at the same startup + per-dispatch-tick validation points §6.3 already
  defines for every tracker.

## `agent_tool_specs/0` / `execute_agent_tool/3`

One tool, documented per §10.5's per-adapter-tool documentation requirement:

- **Name**: `local_tracker_set_state`
- **Input schema**: `{"type": "object", "additionalProperties": false, "required": ["state"],
  "properties": {"state": {"type": "string", "description": "New provider-native state name for the
  current work item."}}}`
- **Mutates tracker state**: yes — the current session's bound issue's `state` field only (see
  data-model.md §2 for the scope restriction).
- **Scope/authorization**: implicit — scoped to the issue bound to the current coding-agent session via
  the same `tracker_settings`/`issue` context every adapter tool already receives
  (`Tracker.execute_bound_agent_tool/4`'s `opts`). No cross-issue mutation is possible through this tool.
- **Result/error semantics**: same `%{"success" => bool, "output" => json_string, "contentItems" =>
  [...]}
` shape `GitHub.AgentTool`/`Codex.DynamicTool.execute/4` already normalize; failure cases: unknown
  target state name is NOT rejected (the local tracker has no fixed enum — any non-empty string is a
  valid state, exactly like every other adapter's `state` field), write/IO failure (disk full, permission
  revoked mid-run) returns `success: false` with a structured error payload.
- **Idempotency**: setting to the current value is a no-op success (data-model.md §2).
- **Rate limits**: none (local filesystem).

## Error categories (§11.4 RECOMMENDED categories this adapter uses)

- `invalid_tracker_config` — bad/unwritable `path`.
- `tracker_response` — JSON present but semantically invalid (bad `format_version`, non-object
  `issues`).
- A local-tracker-specific category, `local_tracker_corrupt`, is used instead of the generic
  `tracker_response`/`tracker_request` categories for the FR-013 established-state-loss case
  specifically, so the orchestrator's operator-visible failure surface can (optionally) distinguish "this
  tracker adapter had a bad response" from "this tracker's own durable state was lost," matching FR-013's
  requirement that this be surfaced as distinct from an ordinary transient read failure.

## What this adapter deliberately does NOT add

- No comment/attachment/PR-metadata APIs (§11 preamble: "Do not add generic comment/state/attachment CRUD
  merely to make providers look alike").
- No multi-writer locking/transaction protocol — single-process durability only, per R1's stated scope.
- No orchestrator-visible schema beyond `Tracker.Issue.t()` — `format_version`/on-disk shape is entirely
  internal to `Local.Store`.
