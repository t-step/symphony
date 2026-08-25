# Contract: `SymphonyElixir.CodingAgent` Behaviour

New internal behaviour. `SymphonyElixir.Codex.AppServer` already satisfies this shape today and is
retrofitted with `@behaviour SymphonyElixir.CodingAgent` (no functional change). This is the seam
`AgentRunner` calls through instead of importing a specific integration module directly. See research.md
R4 for why this shape and R7 for the asymmetry between the two current implementations.

## Callbacks

```text
@callback start_session(workspace :: Path.t(), opts :: keyword()) ::
            {:ok, session :: term()} | {:error, reason :: term()}

@callback run_turn(session :: term(), prompt :: String.t(), issue :: Tracker.Issue.t(), opts :: keyword()) ::
            {:ok, turn_result :: map()} | {:error, reason :: term()}

@callback stop_session(session :: term()) :: :ok
```

### `start_session/2`

- **Input**: `workspace` — the absolute, already-validated per-issue workspace path (never the source
  repo; workspace-safety invariants IV-003/IV-006 apply identically regardless of integration).
  `opts` — at minimum `worker_host: String.t() | nil` (SSH remote-execution target, unchanged from
  today's Codex-only support).
- **Output**: `{:ok, session}` where `session` is an **opaque** term to the caller. `AgentRunner` MUST
  NOT pattern-match on session internals or assume a subprocess is alive after this call returns — Codex's
  session is a live `Port`; Claude Code's session (R7) is inert prep state (workspace + generated MCP
  config path) with no subprocess yet.
- **Failure**: any dependency failure that prevents even attempting a turn (missing executable, invalid
  workspace cwd, MCP config generation failure, etc.) returns `{:error, reason}` and MUST NOT raise —
  this is the seam FR-008.2 routes into the existing attempt failure/retry path through.

### `run_turn/4`

- **Input**: `session` from `start_session/2` (or a prior `run_turn/4`'s session, for the loop below),
  `prompt` (from `PromptBuilder` on turn 1, continuation guidance on later turns — unchanged, this stays
  in `AgentRunner`, not in the behaviour), `issue` (current `Tracker.Issue.t()`, used for
  logging/titling/tool-execution context exactly as today), `opts` — at minimum `on_message:
  (map() -> :ok)` for streaming runtime events upstream to the orchestrator (IV-004's common
  lifecycle/session observability).
- **Output**: `{:ok, turn_result}` where `turn_result` is a map that MUST include a `session_id` (may be
  `nil` only if the integration genuinely has none yet — not expected in practice) usable for logging and
  the status dashboard's existing `session_id`/`turn_count` fields (data-model.md §5). Implementations MAY
  return an updated opaque session term for use by the *next* `run_turn/4` call (Claude Code does, per
  R7 — the `--resume` id changes turn to turn); `AgentRunner`'s continuation loop MUST thread whatever
  session value the previous `run_turn/4` returned into the next call rather than reusing the original
  `start_session/2` result unconditionally.
- **`on_message` events**: MUST emit at minimum the shared subset every integration can produce —
  `session_started`, a terminal per-turn outcome event (success/failure/cancelled-equivalent), and
  `startup_failed` on launch failure — using the same message map shape `Codex.AppServer.emit_message/4`
  already produces (`event`, `timestamp`, plus integration-specific detail fields). Integration-specific
  event names beyond this common subset are permitted (IV-004 does not require identical shape) but MUST
  NOT be required by `AgentRunner`/orchestrator/status-dashboard code to function.
- **Failure**: any turn failure (turn failed, cancelled, timed out, subprocess/process exited unexpectedly,
  tool-call handling error) returns `{:error, reason}` and MUST NOT raise. `AgentRunner.run/3` is the
  only place a `RuntimeError` is raised today (on final `{:error, reason}` after all continuation
  attempts) — that stays unchanged.

### `stop_session/1`

- **Input**: the most recent opaque session term.
- **Output**: always `:ok`. MUST be safe to call even if the underlying resource (process, temp file) is
  already gone (Codex's `stop_port/1` already tolerates `:erlang.port_info/1` returning `:undefined`;
  Claude Code's equivalent tolerates the temp MCP config file already having been removed). MUST be
  called from an `after` block by the caller exactly as `AgentRunner.run_codex_turns/5` already does, so
  cleanup runs on every exit path (success, error, exception).

## Non-goals of this contract

- Does **not** standardize turn/session event names, transport framing, or tool-call wire protocol —
  those stay entirely inside each integration module (Principle VI).
- Does **not** add a 4th callback for tool binding/execution — that continues to flow through
  `Tracker.bind_agent_tools/0` + `Tracker.execute_bound_agent_tool/4`, called directly by each
  integration's own dynamic-tool dispatcher (`Codex.DynamicTool`, `ClaudeCode.DynamicTool`), not through
  `CodingAgent`.
- Does **not** change `AgentRunner`'s continuation policy (`continue_with_issue?/2`,
  `agent.max_turns`, tracker-state-driven continuation) — that logic reads `Tracker` directly and is
  integration-agnostic already.
