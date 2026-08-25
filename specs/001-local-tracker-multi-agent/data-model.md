# Data Model: Local Work Tracking and Selectable Coding-Agent Execution

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

This feature introduces no new orchestrator-facing entity shape beyond what `SPEC.md` §4.1 already
defines (`Issue`, `Workflow Definition`, `Service Config`, `Workspace`, `Run Attempt`, `Live Session`,
`Retry Entry`, `Orchestrator Runtime State`). It adds two adapter-owned entities (the local
work-tracking store's on-disk record, and the coding-agent execution selector) and one new behaviour
contract. Nothing here changes `SymphonyElixir.Tracker.Issue` — both new integrations produce and
consume that exact struct.

## 1. Local Work-Tracking Store (on-disk entity)

Owned entirely by `SymphonyElixir.Local.Store`, a named singleton `GenServer` (started only when
`tracker.kind: local` is the active structural selection) that serializes every read and the one
lifecycle write against the file — never read or written directly by the orchestrator, by any adapter
caller bypassing the GenServer, or by more than one process at a time (research.md R1a; closes the
concurrent-attempt lost-update race a bare `File.write` would have). Satisfies FR-001, FR-004, FR-013.

**Location**: two files, both resolved the same way `workspace.root` already resolves — relative to the
directory containing the active `WORKFLOW.md` unless absolute:

- The data file: config field `tracker.provider.path`, default `.symphony/local_tracker.json`. This
  field is **structural** for `tracker.kind: local` — read once at process start, not hot-reloaded (see
  `contracts/workflow-config-fields.md` and research.md R9a for why a live path change is unsafe here
  specifically, unlike every other tracker kind's `provider.*` fields).
- The establishment marker: `<tracker.provider.path>.established` (default
  `.symphony/local_tracker.json.established`), used only to satisfy FR-013 across restarts — see below.
  Never exposed to the orchestrator or to `Tracker.Issue.t()`.

Both default paths (`.symphony/local_tracker.json`, `.symphony/local_tracker.json.established`) are added
to `elixir/.gitignore` by literal path — mirroring the narrow, path-specific pattern this repo already
uses for `.codex/original-user-prompt.txt` (confirmed: `.codex/` itself is not blanket-ignored, only that
one file), not a blanket `.symphony/` directory ignore. An operator who overrides `tracker.provider.path`
is responsible for gitignoring their own custom path.

**Top-level shape**:

```json
{
  "format_version": 1,
  "issues": {
    "<id>": { "...": "IssueRecord, see below" }
  }
}
```

- `format_version` (integer, REQUIRED) — read-and-refuse-if-unrecognized guard for future format
  changes; not exposed to the orchestrator.
- `issues` (object, REQUIRED, may be empty `{}`) — keyed by the same opaque `id` string used as
  `Issue.id`.

**IssueRecord fields** — a durable superset of `SymphonyElixir.Tracker.Issue` (see §4.1.1 in
`SPEC.md`); the adapter's `fetch_issues_by_states/1` and `fetch_issues_by_ids/1` map each record 1:1
onto `Issue.t()` with no lossy transform:

| Field | Type | Notes |
|---|---|---|
| `id` | string | Stable dispatch identity; also the map key. Adapter-generated on creation (e.g. a short random token) — never reused. |
| `native_ref` | null | The local tracker has no distinct underlying provider ID; always `null`. |
| `identifier` | string | Human-readable, unique within the store; used for workspace key derivation. Adapter validates uniqueness on write. |
| `title` | string | |
| `description` | string or null | |
| `priority` | integer or null | Same `1..4`-ranks-before-null convention as every other adapter (§11.3). |
| `state` | string | Provider-native (here: store-native) state name, e.g. `"todo"`, `"in_progress"`, `"blocked"`, `"done"`. Free-form string, matched against `tracker.active_states`/`terminal_states` like any adapter. |
| `branch_name` | string or null | |
| `url` | string or null | Local tracker has no hosted URL; adapters MAY synthesize a `file://` reference to the record or leave `null`. |
| `assignee_id` | string or null | |
| `labels` | array of strings | Normalized lowercase/trimmed on write, matching §11.3. |
| `blocked_by` | array of blocker refs (`{id, identifier, state}`) | Best-effort; the local tracker records only refs to `id`s present in the same store. |
| `dispatchable` | boolean | REQUIRED, always `true` for every local-tracker record — see research.md R11. There is no `archived`/withdrawn concept: this matches the existing `gitlab/client.ex:198` precedent of an adapter with no structural eligibility exclusion, and gating is fully covered by `state` (active/terminal) and `blocked_by`, both already orchestrator-read. An operator who wants Symphony to stop touching a record moves it to a terminal state, the same lever every other adapter exposes. |
| `created_at` / `updated_at` | RFC 3339 string or null | Adapter stamps `updated_at` on every write. |

**Default active/terminal states** (mirrors the existing `"linear"`/`"memory"` fallback pattern in
`Config.Schema.finalize_settings/1`): `active_states` default `["todo", "in_progress", "blocked"]`,
`terminal_states` default `["done", "cancelled"]`, both overridable via `tracker.active_states` /
`tracker.terminal_states` exactly like every other adapter.

**Established-vs-not-yet-established rule (FR-013, twice-corrected — see research.md R2/R2a)**: file
absence at the data path is not, by itself, a reliable "not yet established" signal, because an
established store's data file can be deleted while Symphony is stopped, which is indistinguishable from
"never used" using only that one file. Unlike the prior corrected pass, `Local.Store`'s own ordinary
read path (used at startup validation and every dispatch tick per `SPEC.md` §6.3) **never writes either
file** — it only ever reads both and reports one of the outcomes below. Establishment is performed
exclusively by the separate, explicit `symphony local-tracker init` operation (research.md R2a), never by
Symphony's running orchestrator process:

| Marker | Data file | Outcome |
|---|---|---|
| absent | absent | **Not yet initialized.** `{:error, :local_tracker_not_initialized}` — operator-visible startup/dispatch-preflight failure; remediation is `symphony local-tracker init`, never an automatic write. |
| absent | present (valid or not) | **Ambiguous — never auto-resolved.** `{:error, {:local_tracker_ambiguous_state, :marker_missing}}` (partial restore, interrupted `init`, or a hand-placed file). Data is left untouched; resolved only by an explicit re-run of `init`. |
| present | present, valid | Normal operation. |
| present | absent | **FR-013 established-state loss.** `{:error, {:local_tracker_corrupt, :missing_after_established}}`; `Local.Store` MUST NOT recreate an empty store. |
| present | present, invalid/corrupt | **FR-013 established-state loss.** `{:error, {:local_tracker_corrupt, reason}}`. |
| present, unreadable/corrupt | (any) | Same class as the row above — never silently ignored or rewritten. |

A deliberate reset is `symphony local-tracker init --reset` (research.md R2a) — always explicit, never
inferred from file absence or loss.

**Write discipline**: every mutation `local-tracker init` performs (the one-time fresh-store
initialization, or `--reset`'s delete-then-recreate) writes to a sibling temp file in the same directory
and renames it over its target path (POSIX atomic rename), so a crash mid-write cannot leave a
torn/partial file — the existing file on disk is either the old complete version or the new complete
version, never a fragment. This is the same "corruption must be a real integrity failure, not a
self-inflicted torn write" property `WorkflowStore` already gets for free by only reading `WORKFLOW.md`,
now applied to both the data file and the marker file. The one ordinary-runtime write this store ever
performs — the `local_tracker_set_state` agent-tool lifecycle mutation (§2 below) — uses the same atomic
path and is serialized through the `Local.Store` GenServer (§ above, research.md R1a); `init`/`--reset`
are separate, short-lived CLI invocations outside Symphony's running process, not synchronized with a
live `Local.Store` GenServer (research.md R2a's stated concurrency scope, unchanged from R1a's original
single-deployment boundary).

## 2. Local Tracker Agent Tool (agent-invoked, host-executed)

Satisfies FR-003, FR-011 — reuses the existing OPTIONAL `Tracker` callbacks
(`agent_tool_specs/0`, `execute_agent_tool/3`) that GitHub/GitLab/Jira/Linear/Asana already implement;
adds no orchestrator API.

- **Tool name**: `local_tracker_set_state`
- **Input schema**: `{ "state": string (required) }` — the coding-agent session already carries the
  current issue as turn context (`issue.id`), so the tool only needs the target state name, mirroring
  how `github_api`'s tool only needs REST call shape, not issue identity.
- **Mutation semantics**: rewrites `issues[<current issue id>].state` and `updated_at` in the store via
  the same atomic-write path as §1, and returns success/failure as a structured `ToolResult`
  (`%{"success" => bool, "output" => ..., "contentItems" => [...]}`) exactly like `GitHub.AgentTool`'s
  response shape.
- **Scope**: can mutate only the state field of the issue bound to the current session (via
  `Tracker.bind_agent_tools/0`'s captured `tracker_settings` + the `issue:` execution context already
  threaded through `Codex.DynamicTool.execute/4` and, for Claude Code, `ClaudeCode.MCPServer`'s HTTP tool
  handler — see `contracts/coding-agent-behaviour.md` and research.md R6 for the corrected process
  topology — calling the same `Tracker.execute_bound_agent_tool/4`) — it cannot target an arbitrary `id`,
  so a coding-agent session can only ever move its own assigned work item.
- **Idempotency**: setting a state to its current value is a no-op success (matches typical hosted-tracker
  idempotent transition behavior; avoids spurious `updated_at` churn on repeated calls in one turn).
- **Credentials**: none — `secret_environment_names/1` returns `[]`, matching `Tracker.Memory`; the
  local tracker has no secret to leak into a coding-agent child process (satisfies FR-009 trivially for
  this integration).

## 3. Coding-Agent Execution Integration Selector (config entity)

New `Config.Schema` embed, `agent_execution`, sibling to the existing `codex` embed. Satisfies FR-005,
FR-006, FR-007, FR-010.

| Field | Type | Default | Notes |
|---|---|---|---|
| `kind` | string | `"codex"` | `"codex" \| "claude_code"`. Absent/unset defaults to `"codex"` — preserves today's unconfigured-integration behavior (spec Edge Cases, FR-006). |

Reading `agent_execution.kind` happens once at process start (see `IV-005` in Constitution Check); the
orchestrator/`AgentRunner` resolve the concrete coding-agent module from this value exactly once, the
same way `WorkflowStore`'s wholesale-reload model already treats other resource-bound settings.

**Cross-field validation (research.md R6a)**: `agent_execution.kind: claude_code` combined with a
non-empty `worker.ssh_hosts` is invalid configuration — Claude Code execution supports local execution
only in this feature (remote `worker_host`/SSH execution remains fully supported, unchanged, for
`agent_execution.kind: codex`). This is validated in the same `Config.validate_settings/1` pipeline every
other config check already uses (`config.ex:122`), failing startup the same way a missing hosted-tracker
credential already does.

Claude-Code-specific runtime settings (command/launch flags, permission-mode equivalent,
timeouts) live in their own sibling `claude_code` embed, mirroring the existing `codex` embed's shape —
so provider-specific fields never collide with or require reading Codex's `codex.*` fields (FR-007,
FR-009). Exact field list is finalized in `research.md` once the Claude Code CLI's invocation contract
is confirmed.

## 4. `SymphonyElixir.CodingAgent` Behaviour (new formal contract)

Extracted, not invented: this is the existing public shape of `SymphonyElixir.Codex.AppServer` that
`AgentRunner` already depends on (verified against the actual current `start_session/2`/`run_turn/4`/
`stop_session/1` signatures and return shapes, not merely assumed — research.md R4), now named so a
second implementation can satisfy it. The session identity a `CodingAgent` implementation returns from
`start_session/2` is fixed for the lifetime of one run and is never replaced by `run_turn/4` — this holds
for both Codex (`thread_id`, captured once) and Claude Code (a Symphony-generated `--session-id` UUID,
captured once; research.md R7) — so `run_turn/4` returns only `{:ok, turn_result}`, with no session value
in play. See [`contracts/coding-agent-behaviour.md`](./contracts/coding-agent-behaviour.md) for the full
callback contract.

For Claude Code specifically, `start_session/2` also captures `Tracker.bind_agent_tools/0`'s binding and
the current issue once, handing both directly to the one `ClaudeCode.MCPServer` process it starts for
this run's lifetime (research.md R6a) — there is no shared/global binding table anywhere in this design;
process-local state started fresh per run is the entire isolation mechanism between concurrent runs.
`worker_host` is rejected by `ClaudeCode.AppServer.start_session/2` (`{:error,
:remote_worker_not_supported}`) — Claude Code execution is local-only in this feature (research.md R6a;
`agent_execution.kind: codex` is unaffected and keeps full `worker_host` support).

## 5. Shared Runtime/Telemetry Fields (no rename)

`Orchestrator.State`'s per-issue `running` entry and the `codex_totals`/`codex_rate_limits` aggregate
fields keep their existing `codex_*`-prefixed names (`codex_app_server_pid`, `codex_input_tokens`,
`last_codex_event`, etc. — `orchestrator.ex`/`status_dashboard.ex`/`presenter.ex`, ~74 references).
Per Constitution Principle II and IV-004 ("common lifecycle/session observability across every
integration, without requiring identical telemetry shape"), the Claude Code integration populates these
same fields with its own session/turn/token data rather than triggering a rename sweep; a `session_id`,
`turn_count`, and token counts remain populated regardless of which `agent_execution.kind` produced the
run. Integration-specific detail beyond that common subset (if any) is carried in the existing free-form
message payload passed to `codex_message_handler`/`send_codex_update`, not in new top-level state keys.
