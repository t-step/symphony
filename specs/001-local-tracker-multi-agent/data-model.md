# Data Model: Local Work Tracking and Selectable Coding-Agent Execution

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

This feature introduces no new orchestrator-facing entity shape beyond what `SPEC.md` §4.1 already
defines (`Issue`, `Workflow Definition`, `Service Config`, `Workspace`, `Run Attempt`, `Live Session`,
`Retry Entry`, `Orchestrator Runtime State`). It adds two adapter-owned entities (the local
work-tracking store's on-disk record, and the coding-agent execution selector) and one new behaviour
contract. Nothing here changes `SymphonyElixir.Tracker.Issue` — both new integrations produce and
consume that exact struct.

## 1. Local Work-Tracking Store (on-disk entity)

Owned entirely by `SymphonyElixir.Local.Store`; never read or written by the orchestrator directly.
Satisfies FR-001, FR-004, FR-013.

**Location**: one JSON file, path resolved the same way `workspace.root` already resolves — relative
to the directory containing the active `WORKFLOW.md` unless absolute. Config field:
`tracker.provider.path`, default `.symphony/local_tracker.json`.

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
| `dispatchable` | boolean | REQUIRED, explicit. The local tracker has no provider-side eligibility rule beyond "record exists and is not archived" — `dispatchable` is `true` unless the operator/tool explicitly sets an `archived`/withdrawn record. |
| `created_at` / `updated_at` | RFC 3339 string or null | Adapter stamps `updated_at` on every write. |

**Default active/terminal states** (mirrors the existing `"linear"`/`"memory"` fallback pattern in
`Config.Schema.finalize_settings/1`): `active_states` default `["todo", "in_progress", "blocked"]`,
`terminal_states` default `["done", "cancelled"]`, both overridable via `tracker.active_states` /
`tracker.terminal_states` exactly like every other adapter.

**Established-vs-not-yet-established rule (FR-013)**: file absence at the configured path IS the
"not yet established" signal — `Local.Store` initializes and atomically writes a fresh
`{"format_version": 1, "issues": {}}` the first time it is asked to read from a missing path. Any other
read failure (file exists but: JSON decode error, `format_version` mismatch, wrong top-level shape,
permission denied, not-a-regular-file) is an established-store failure: `Local.Store` returns
`{:error, {:local_tracker_corrupt, reason}}` and never writes to the path. This makes corruption
detection a pure function of "did open+decode succeed," with no separate marker file needed.

**Write discipline**: every mutation (agent-tool lifecycle write, or the one-time fresh-store
initialization) writes to a sibling temp file in the same directory and renames it over the target path
(POSIX atomic rename), so a crash mid-write cannot leave a torn/partial file — the existing file on disk
is either the old complete version or the new complete version, never a fragment. This is the same
"corruption must be a real integrity failure, not a self-inflicted torn write" property `WorkflowStore`
already gets for free by only reading `WORKFLOW.md`.

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
  threaded through `Codex.DynamicTool.execute/4` and its Claude Code MCP equivalent) — it cannot target
  an arbitrary `id`, so a coding-agent session can only ever move its own assigned work item.
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

Claude-Code-specific runtime settings (command/launch flags, permission-mode equivalent,
timeouts) live in their own sibling `claude_code` embed, mirroring the existing `codex` embed's shape —
so provider-specific fields never collide with or require reading Codex's `codex.*` fields (FR-007,
FR-009). Exact field list is finalized in `research.md` once the Claude Code CLI's invocation contract
is confirmed.

## 4. `SymphonyElixir.CodingAgent` Behaviour (new formal contract)

Extracted, not invented: this is the existing public shape of `SymphonyElixir.Codex.AppServer` that
`AgentRunner` already depends on, now named so a second implementation can satisfy it. See
[`contracts/coding-agent-behaviour.md`](./contracts/coding-agent-behaviour.md) for the full callback
contract.

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
