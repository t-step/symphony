# Contract: Local Work-Tracking Source (`tracker.kind: local`)

Follows the exact adapter-profile documentation shape `SPEC.md` §11.2 already requires of every tracker
adapter ("Each adapter MUST publish a compact profile ... exact supported `tracker.kind` value; exact
`tracker.provider` keys ...").

## `tracker.kind`

`"local"`.

## `tracker.provider` keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `path` | string | `.symphony/local_tracker.json` | Resolved relative to the directory containing the active `WORKFLOW.md`, same rule as `workspace.root` (`Config.local_workspace_root/0`). `~` and `$VAR` expansion apply per `SPEC.md` §6.1. **Structural, not dynamically reloaded** — read once at process start alongside `tracker.kind`; a change takes effect only on the next restart (see `contracts/workflow-config-fields.md` and research.md R9a — a live path change would silently switch the orchestrator to a different data source's identity mid-flight, unlike every other tracker kind's `provider.*` fields, which only ever identify how to reach the *same* dataset). |

No secret keys — `secret_environment_names/1` always returns `[]` (data-model.md §2).

Every read (`fetch_issues_by_states/1`, `fetch_issues_by_ids/1`) and the one write
(`local_tracker_set_state`) go through the singleton `SymphonyElixir.Local.Store` `GenServer`, which
serializes access to the underlying file(s) — no adapter code touches the filesystem directly (research.md
R1a; closes a concurrent-attempt lost-update race that would otherwise exist once more than one
`Task.Supervisor`-spawned attempt can call the write tool at overlapping instants).

## `tracker.active_states` / `tracker.terminal_states`

Same override mechanism as every adapter. Defaults (mirroring the existing `"linear"`/`"memory"`
fallback branch in `Config.Schema.finalize_settings/1`):

- `active_states` default: `["todo", "in_progress", "blocked"]`
- `terminal_states` default: `["done", "cancelled"]`

## `fetch_issues_by_states/1`

Reads the store via `Local.Store` (R2/R2a — see data-model.md §1's decision table). `Local.Store` never
writes during a read, under any condition: both files absent → `{:error, :local_tracker_not_initialized}`
(remediation: `symphony local-tracker init`); data present without the marker → `{:error,
{:local_tracker_ambiguous_state, :marker_missing}}` (remediation: re-run `init`, which completes
establishment without altering the data); both present and valid → return normally; marker present with
the data file missing or unparseable → `{:error, {:local_tracker_corrupt, reason}}`, never a silent
reset. Returns every `IssueRecord` whose normalized `state` matches one of the requested (normalized)
state names, mapped 1:1 to `Tracker.Issue.t()`. Empty `state_names` returns `{:ok, []}` without touching
the file, per §11.1.

## `fetch_issues_by_ids/1`

Same read/corruption behavior as above; returns the subset of records whose `id` is in the requested
set. IDs not present in the store are omitted (never synthesized), matching §11.1's "omission means no
longer visible" rule — this is exactly why `tracker.provider.path` must stay structural (see above): a
live path change would make this omission rule fire for every issue from the old file, not just genuinely
removed ones. Empty `issue_ids` returns `{:ok, []}` without touching the file.

## `validate_config/1`

- `path`'s parent directory must be creatable/writable (validated the same class of check
  `PathSafety`/`Workspace` already performs for `workspace.root`).
- **The store must already be initialized** — `validate_config/1` fails with
  `{:error, :local_tracker_not_initialized}` (or `{:error, {:local_tracker_ambiguous_state, reason}}`,
  research.md R2) if `local-tracker init` (research.md R2a) has not yet been run against this path. This
  slots into the exact same `WorkflowStore.init/1` → `Config.validate_settings/1` →
  `Tracker.validate_config/1` chain every hosted adapter's credential/endpoint check already uses — no new
  validation call site, only a new failure reason a preexisting mechanism can already surface.
- No provider-side network/auth to validate (unlike GitHub/GitLab/Jira/Linear), so beyond the
  initialization check above, this is a filesystem reachability check only, run at the same startup +
  per-dispatch-tick validation points §6.3 already defines for every tracker.

## `symphony local-tracker init` (explicit initialization operation)

See research.md R2a for the full contract. A packaged-CLI subcommand (`CLI.evaluate/2`), not a `mix` task
— the production deployment target (Burrito single binary) has no `mix`/Elixir toolchain available, so
this must be reachable from `bin/symphony` itself. Loads the given `WORKFLOW.md`, resolves
`tracker.provider.path`, and atomically creates the data file then the marker file; refuses to overwrite
an already-established store unless `--reset` is passed; safely completes establishment (writes only the
marker) if the data file already exists and parses validly with the marker missing. Does not start the
orchestrator. This is the *only* code path in this feature that ever writes the data file's initial
content or the marker file — `Local.Store`'s own read path (`fetch_issues_by_states/1`,
`fetch_issues_by_ids/1`, `validate_config/1`) never writes either file.

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
- `local_tracker_not_initialized` — neither the data file nor the marker exists. Distinct from
  `invalid_tracker_config`: the config itself (the `path` value) is valid, but nothing has been
  provisioned at it yet. Remediation: `symphony local-tracker init` (research.md R2a).
- `local_tracker_ambiguous_state` — the data file exists but the marker does not (research.md R2's
  ambiguous row: partial restore, interrupted `init`, or a hand-placed file). Never auto-resolved by
  ordinary reads; remediation is the same explicit `init` re-run, which completes establishment without
  altering existing valid data.
- A local-tracker-specific category, `local_tracker_corrupt`, is used instead of the generic
  `tracker_response`/`tracker_request` categories for the FR-013 established-state-loss case
  specifically, so the orchestrator's operator-visible failure surface can (optionally) distinguish "this
  tracker adapter had a bad response" from "this tracker's own durable state was lost," matching FR-013's
  requirement that this be surfaced as distinct from an ordinary transient read failure. The reason
  distinguishable by `reason` — `:missing_after_established` (marker present, data file absent) vs. a
  decode/shape error (data file present but unparseable) — both surface through this same
  `local_tracker_corrupt` category; the distinction is diagnostic detail, not a different category,
  since both are FR-013 established-state-loss from the orchestrator's point of view. `local_tracker_corrupt`
  is categorically distinct from `local_tracker_not_initialized`/`local_tracker_ambiguous_state` above:
  the former means the store *was* established and something went wrong; the latter two mean it never
  reached a confirmed-established state in the first place.

## Concurrency

All reads and the one write go through the singleton `Local.Store` `GenServer` (data-model.md §1,
research.md R1a) — this adapter's own `Adapter`/`AgentTool` modules never call `File.read`/`File.write`
directly. This is what makes it safe for `Task.Supervisor`-spawned concurrent attempts for different
issues to each call `local_tracker_set_state` without one silently overwriting the other's write.

## Dispatchable

`dispatchable` is always `true` for every record this adapter produces — there is no archived/withdrawn
concept (research.md R11; matches the existing `gitlab/client.ex` precedent of an adapter with no
structural eligibility exclusion). Gating is `state` (active/terminal) and `blocked_by`, both already
orchestrator-owned exactly as for every other adapter.

## What this adapter deliberately does NOT add

- No comment/attachment/PR-metadata APIs (§11 preamble: "Do not add generic comment/state/attachment CRUD
  merely to make providers look alike").
- No OS-level file locking (`flock`) or cross-process/cross-host multi-writer protocol — only concurrency
  *within* one Symphony deployment (multiple `Task.Supervisor`-spawned attempts in the same BEAM VM) is
  handled, via the in-process `Local.Store` `GenServer` (research.md R1a), not concurrent writers from
  separate OS processes/hosts, which remains out of scope per R1's stated single-deployment durability
  goal.
- No orchestrator-visible schema beyond `Tracker.Issue.t()` — `format_version`/on-disk shape is entirely
  internal to `Local.Store`.
