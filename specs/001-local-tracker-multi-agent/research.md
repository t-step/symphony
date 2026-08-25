# Phase 0 Research: Local Work Tracking and Selectable Coding-Agent Execution

Feature: [spec.md](./spec.md) | Plan: [plan.md](./plan.md)

The frozen spec left every concrete mechanism to this planning stage (FR-003/FR-011: "left unspecified
here and belongs to the planning stage"; FR-013: "by whatever concrete initialization mechanism the
planning stage selects"). This document resolves each of those with a decision, rationale, and the
alternatives considered, grounded in the current implementation (`elixir/lib/symphony_elixir/`) and
upstream `SPEC.md`.

## R1. Local work-tracking source: storage mechanism

**Decision**: A single durable JSON file per deployment (default
`.symphony/local_tracker.json`, path resolved the same way `workspace.root` already resolves relative
to `WORKFLOW.md`), read/written with `Jason` (already a dependency), with all writes going through a
write-temp-file + atomic-rename sequence.

**Rationale**: FR-004 only requires surviving a process restart on the same host — not concurrent
multi-writer access, not a query language, not multi-GB scale. Constitution Principle V (Avoid
Unnecessary Abstraction) and II (Minimize Fork Delta) both weigh against introducing a SQL engine: `ecto`
is already a dependency but is used purely for `embedded_schema` config validation (`Config.Schema`),
not as a database connection — adding real SQL storage would require `ecto_sql` + a DB adapter (e.g.
`ecto_sqlite3`) + a `Repo` + migrations, none of which exist in this codebase today. A plain JSON file
needs zero new dependencies, is human-readable/git-diffable (fitting the "repository-owned,
version-controlled" philosophy `SPEC.md` §5.1 already applies to `WORKFLOW.md`), and is trivially
inspectable by "a person or another tool" per the spec's edge case about out-of-band edits.

**Alternatives considered**:
- *SQLite via a new `ecto_sqlite3` dependency* — rejected: real new dependency + migration machinery for
  a workload of "poll and update a handful of local records," contradicting Principle V.
- *`:dets` (OTP built-in term storage)* — rejected: binary format is not human-readable/diffable, and
  `:dets` has known table-size and corruption-recovery quirks that add operational surface for no
  benefit at this scale.
- *One file per issue in a directory* — considered for git-diff friendliness (one issue changed = one
  file changed) but rejected as first-cut scope: it requires directory-level atomicity reasoning
  (rename a whole tree is not atomic) and a listing/index step that a single JSON file gets for free.
  Left as a documented future refinement if operators report merge-conflict pain, not required by any
  FR/SC here.

## R2. Local tracker: distinguishing "not yet established" from "corrupted" (FR-013)

**Decision**: File-absence-at-configured-path *is* the "not yet established" signal. `Local.Store`
initializes a fresh `{"format_version": 1, "issues": {}}` file (via the same atomic write path) only
when the configured path does not exist. Any other failure to obtain a valid store at that path — JSON
decode error, unexpected top-level shape, unrecognized `format_version`, permission denied, path exists
but is not a regular file — is treated as an established-store failure and returned as an
operator-visible error; `Local.Store` never overwrites a path that exists but failed to parse.

**Rationale**: This requires no separate "has this ever been initialized" marker or bootstrap
timestamp — existence of a valid file at the path already carries that information, and it composes
cleanly with the atomic-write guarantee from R1 (a properly-written file is never left mid-write, so a
parse failure on an existing file is a genuine integrity problem, not a torn write racing initialization).

**Alternatives considered**: A separate `.initialized` marker file was considered and rejected as an
extra moving part with no behavior it enables beyond what "does the target path already exist" already
gives for free.

## R3. Local tracker: agent-invoked lifecycle-write mechanism (FR-003, FR-011)

**Decision**: Implement the local tracker as a normal `SymphonyElixir.Tracker` adapter that also
implements the existing OPTIONAL `agent_tool_specs/0` + `execute_agent_tool/3` callbacks (exactly the
pattern `GitHub.Adapter`/`GitHub.AgentTool` already establish), exposing one tool,
`local_tracker_set_state`, that rewrites the current session's bound issue's `state` field via the R1
atomic-write path.

**Rationale**: FR-011 explicitly requires reusing "Symphony's existing tracker-write boundary" rather
than adding orchestrator-owned write APIs — `Tracker.bind_agent_tools/0` and
`Tracker.execute_bound_agent_tool/4` already exist precisely for this, are already provider-agnostic
(dispatch by adapter, not by tool name), and are already wired into both the Codex dynamic-tool channel
(`Codex.DynamicTool`) and — per R6 below — the new Claude Code MCP channel. Zero new orchestrator
surface; the local tracker looks, to `AgentRunner`/`Codex.AppServer`/the new Claude Code integration,
exactly like any other tracker with provider-native tools.

**Alternatives considered**: A dedicated orchestrator-level "local tracker write" function was
rejected outright — it is precisely what FR-011 rules out.

## R4. `SymphonyElixir.CodingAgent` behaviour shape

**Decision**: Define a new behaviour with the three callbacks `Codex.AppServer` already exposes as its
public API — `start_session(workspace, opts) :: {:ok, session} | {:error, reason}`,
`run_turn(session, prompt, issue, opts) :: {:ok, turn_result} | {:error, reason}`, and
`stop_session(session) :: :ok` — and retrofit `Codex.AppServer` with `@behaviour SymphonyElixir.CodingAgent`
(no functional change; it already satisfies this shape). `AgentRunner` resolves which module to call via
`Config` (see R9) instead of hardcoding `alias SymphonyElixir.Codex.AppServer`.

**Rationale**: `AgentRunner.run_codex_turns/5` is the single call site that drives session lifecycle
(`start_session` once, `run_turn` per turn in a loop bounded by `agent.max_turns` and tracker-driven
continuation, `stop_session` in an `after` block). That loop, the retry/backoff decision after a failed
turn, and the continuation decision (`continue_with_issue?/2`, which reads back from `Tracker`) are all
orchestration concerns that must stay unchanged per IV-002 — they belong above this seam, not inside it.
Naming and formalizing exactly the shape already implicitly relied upon is the smallest possible
change: no new session-lifecycle concepts, no generic multi-provider registry (explicitly out of scope
per the spec's Non-Goals), just an interface extracted from working code.

**Alternatives considered**: A richer behaviour exposing lower-level primitives (raw message send/
receive) was rejected — it would leak Codex's JSON-RPC transport shape into the contract, violating
Principle VI (protocol handling must stay localized to its own integration) and forcing Claude Code's
integration to fake a foreign transport model instead of using its own.

## R5. Claude Code CLI: non-interactive launch and streaming

**Decision**: Launch per turn as `claude -p "<prompt>" --output-format stream-json --verbose
--include-partial-messages`, spawned the same way `Codex.AppServer` already spawns `codex app-server` —
via `Port.open/2` with `cd:` set to the workspace path (Claude Code has no dedicated cwd flag; process
working directory is the control, matching how Codex is launched today via a `bash -lc "cd ... && exec
..."` wrapper) — reading complete newline-delimited JSON lines off stdout the same way
`AppServer.receive_loop/6` already does for Codex's JSON-RPC stream.

**Rationale/evidence**: Confirmed against current Claude Code CLI documentation (`code.claude.com/docs`:
`headless.md`, `cli-reference.md`, `agent-sdk/streaming-output.md`) that `-p`/`--print` is the
non-interactive entry point and `--output-format stream-json` (with `--verbose` required for streaming,
and `--include-partial-messages` for incremental deltas) produces line-delimited JSON events — the same
transport shape (one JSON object per line on stdout) `Codex.AppServer`'s line-buffered `Port` reader
already handles, so the existing receive-loop pattern generalizes without a new transport abstraction.
Exit codes are `0` (success), `1` (failure), `130`/`143` (signal termination) — mapped the same way
`Codex.AppServer` already maps `port_exit` today.

**Confidence note**: exact event-type names inside the stream-json payloads (the Claude Code analogue of
Codex's `turn/completed`/`turn/failed`) were not independently re-verified line-by-line against a live
CLI run in this planning pass and MUST be confirmed against the installed Claude Code CLI version's own
`--help`/schema output during implementation, the same way `SPEC.md` §10 already requires implementers to
treat the *targeted* Codex app-server version as the protocol source of truth rather than the spec text.

## R6. Claude Code: tool exposure (tracker agent tools)

**Decision**: Symphony hosts a short-lived local stdio MCP server (a new `ClaudeCode.MCPServer`) for the
duration of one run, and points the `claude` CLI at it per-invocation via `--mcp-config <path-to-a
per-run-generated JSON file>`. The MCP server process, on a tool call, dispatches to
`Tracker.execute_bound_agent_tool/4` exactly like `Codex.DynamicTool.execute/4` does today — same
adapter binding, same tracker tools, different wire protocol.

**Rationale/evidence**: Claude Code's tool-exposure mechanism is MCP (Model Context Protocol), not
Codex's proprietary `dynamicTools`/`item/tool/call` JSON-RPC pair. Per `--mcp-config`'s documented
behavior, the *client* (`claude`) spawns the configured MCP server as its own child process from the
`command`/`args` in that config — so Symphony's role is to generate that config (pointing at a small
executable entry point that runs the MCP server loop) before launching `claude`, not to pre-start a
server the CLI connects out to. This keeps FR-007's localization requirement intact: the MCP stdio
JSON-RPC framing lives entirely inside `ClaudeCode.MCPServer`/`ClaudeCode.DynamicTool`, and `Tracker`
itself stays protocol-agnostic (it already is — `execute_bound_agent_tool/4` takes tool name + arguments
+ opts, with no assumption about which wire protocol produced them).

**Alternatives considered**: Skipping tool exposure entirely for Claude Code (agent can only edit files,
never call `local_tracker_set_state` or `github_api`) was rejected — it would silently break FR-003's
workflow-directed lifecycle mutation and any hosted-tracker provider-native tool for Claude-Code-executed
work, which nothing in the spec permits as a Claude-Code-specific carve-out.

## R7. Claude Code: session/turn continuation model

**Decision**: `ClaudeCode.AppServer.start_session/2` performs only workspace/MCP-config preparation and
returns an opaque session map with `session_id: nil` (not yet known — Claude Code assigns it on first
run) plus the prepared MCP config path; it does **not** spawn a long-lived process. Each
`ClaudeCode.AppServer.run_turn/4` call spawns a fresh `claude -p` process for that turn: the first turn
omits `--resume`, and every subsequent turn passes `--resume <session_id>` using the session ID captured
from the previous turn's stream-json output. `stop_session/1` removes the per-run MCP config temp file
(there is no live process to terminate in the normal case).

**Rationale/evidence**: Unlike the Codex app-server (one long-lived subprocess, one open `thread_id`
reused via JSON-RPC calls into that same live process for every turn), Claude Code's headless mode is
one full process invocation per turn; continuity across turns is transcript-based (stored under
`~/.claude/projects/...`) and resumed with `--resume <session-id>` or `--continue`, per Claude Code's own
session-management documentation. This is exactly the kind of provider-specific lifecycle mechanic
Principle VI requires to stay localized: `CodingAgent`'s 3-callback contract (R4) deliberately does not
assume "a process is now running" after `start_session`, so this asymmetry is fully absorbed inside
`ClaudeCode.AppServer` and invisible to `AgentRunner`'s turn loop, which only ever sees
`{:ok, session}` / `{:ok, turn_result}` / `:ok`.

**Confidence note**: whether `--resume` vs `--continue` is the more robust choice for Symphony's
explicit-session-id use case should be re-confirmed against the installed CLI version at implementation
time; `--resume <id>` is used here because it targets an exact prior session rather than "most recent,"
which matters once multiple workspaces/issues run concurrently on one host.

## R8. Claude Code: unattended auto-approval and credential isolation

**Decision**: Launch with a fully-unattended permission mode (Claude Code's documented equivalent of
"auto-approve for the session," analogous to Codex's `approval_policy` reject-everything default) and
authenticate via `ANTHROPIC_API_KEY` scoped to the Claude Code subprocess's environment only. Following
the exact pattern `Codex.AppServer.tracker_secret_unset_command/1` and `tracker_secret_port_env/1`
already use to strip tracker secrets from the Codex child's environment, the Claude Code launch
environment explicitly excludes `OPENAI_API_KEY`/Codex's own auth file, and the Codex launch environment
(unchanged) continues to exclude `ANTHROPIC_API_KEY`.

**Rationale/evidence**: FR-009 is a hard requirement ("MUST NOT be required by, or leak into, another
coding-agent execution integration"). Since FR-010 already guarantees only one coding-agent execution
integration is ever active per deployment, isolation only has to prevent the *inactive* integration's
credentials from being readable by the *active* one's child process — the existing per-process `env:`
allow-list pattern in `Port.open/2` (already used for tracker secrets) generalizes directly: only pass
through the environment variables the active integration's profile documents needing.

**Confidence note**: the exact current permission-mode flag/enum name (candidates surfaced during
research: `--permission-mode bypassPermissions` or `acceptEdits`, possibly combined with
`--allowedTools`) was not independently re-verified against a live CLI run in this pass and MUST be
confirmed against the installed Claude Code CLI version's `--help` output during implementation — this
mirrors how `SPEC.md` §10.5 already requires each Codex-integration implementation to document its own
chosen approval/sandbox posture rather than the spec prescribing one. Symphony's documented policy
choice, once confirmed, MUST fail (not silently hang) any turn that still requires interactive
confirmation, matching the "run MUST NOT stall indefinitely waiting for user input" requirement Codex's
integration already satisfies.

## R9. Coding-agent execution integration selection: config surface and reload semantics

**Decision**: New `agent_execution.kind` WORKFLOW.md field (`"codex"` default, or `"claude_code"`),
resolved once at process start alongside `tracker.kind` (see Constitution Check / IV-005), not
hot-reloaded. `AgentRunner` resolves the concrete `CodingAgent` module from this value at the point it
currently hardcodes `Codex.AppServer`.

**Rationale**: Directly required by FR-005/FR-006/FR-010 and by IV-005 as already revised in the frozen
spec (structural, restart-only selection). No new decision beyond what the spec already settled; captured
here only to record where in the config pipeline (`Config`/`Config.Schema`, same place `codex.*` is
resolved today) the field lives.

## R10. Runtime/telemetry field reuse (no rename)

**Decision**: Both integrations populate the existing `codex_*`-prefixed fields in
`Orchestrator.State`'s running-issue map and status/dashboard code (`codex_app_server_pid`,
`codex_input_tokens`/`codex_output_tokens`/`codex_total_tokens`, `last_codex_event`,
`last_codex_message`, `last_codex_timestamp`, `turn_count`, `codex_totals`, `codex_rate_limits`) rather
than introducing integration-neutral field names.

**Rationale**: ~74 references to these field names span `orchestrator.ex`, `status_dashboard.ex`, and
`presenter.ex`. IV-004 requires common lifecycle/session observability across integrations but
explicitly does not require identical telemetry *shape*; Constitution Principle II (Minimize Fork Delta)
weighs against a rename sweep across three files and their tests for a purely cosmetic improvement. This
is recorded as a conscious, reversible naming choice, not an oversight — a future rename remains open if
a third integration makes the Codex-specific naming genuinely confusing.
