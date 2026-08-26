# Contract: `SymphonyElixir.CodingAgent` Behaviour

New internal behaviour. `SymphonyElixir.Codex.AppServer` already satisfies this shape today and is
retrofitted with `@behaviour SymphonyElixir.CodingAgent` (no functional change). This is the seam
`AgentRunner` calls through instead of importing a specific integration module directly. See research.md
R4 for why this shape (verified against `Codex.AppServer`'s actual current signatures, not merely
assumed) and R7 for the asymmetry between the two current implementations and how the session-identity
model below was corrected during planning review.

**Session identity is fixed at `start_session/2` and never changes for the rest of one run.** Both
current implementations satisfy this: Codex's `thread_id` is captured once in `start_session/2` and
reused unchanged for every continuation turn (matches upstream `SPEC.md` §10.2: "Reuse the same
`thread_id` for all continuation turns inside one worker run"); Claude Code's session identity is a
Symphony-generated UUID, also captured once in `start_session/2` and passed to the CLI via `--session-id`
on turn 1 and `--resume` on every later turn (research.md R7). Consequently `run_turn/4` never needs to
return a new session value, and does not — this contract previously said implementations "MAY return an
updated opaque session term" for `AgentRunner` to thread forward, which was corrected during planning
review: `AgentRunner.do_run_codex_turns/8` never implemented that threading (its recursive call always
reuses the original `start_session/2` result, `agent_runner.ex:117-126`), and `Codex.AppServer.run_turn/4`'s
actual return shape has no session-shaped key to carry one (`app_server.ex:114-120`). The corrected
contract below matches what the code has always actually done.

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
  `opts` — at minimum `worker_host: String.t() | nil` (SSH remote-execution target). **Codex** supports
  `worker_host` unchanged, exactly as today. **Claude Code does not** — it is local execution only in this
  feature (research.md R6a); `ClaudeCode.AppServer.start_session/2` MUST return
  `{:error, :remote_worker_not_supported}` if invoked with a non-nil `worker_host` (defense in depth — the
  primary enforcement point is startup config validation rejecting `agent_execution.kind: claude_code`
  combined with a non-empty `worker.ssh_hosts`, data-model.md §3). This is a deliberate, documented scope
  boundary, not an oversight: Symphony's remote-worker execution model has no shared filesystem and no
  existing remote-file-delivery mechanism (confirmed by direct trace of `ssh.ex`/`workspace.ex`), and nothing
  in the frozen spec requires Claude Code to support it (confirmed: `worker_host`/SSH is not mentioned in
  `spec.md` or upstream `SPEC.md` as a requirement; the spec's own Assumptions permit Claude Code not
  exposing every Codex-specific capability).

  `opts` may also carry `issue: Tracker.Issue.t()`, a **Claude-Code-specific required extension key**, not
  part of the shared minimum every implementation must accept: `ClaudeCode.AppServer.start_session/2`
  returns `{:error, :issue_required}` if it is absent, because the current work item must be bound to the
  per-run `ClaudeCode.MCPServer` (R6a) at listener-start time, before any turn runs — unlike Codex, which
  only needs the issue at `run_turn/4` time (its own `issue` positional parameter, unchanged). Passing
  `issue:` to `Codex.AppServer.start_session/2` is harmless and required to remain so: Codex's
  implementation only reads `opts[:worker_host]` and ignores unrecognized keys, so a caller (`AgentRunner`)
  MAY pass `issue: issue` unconditionally regardless of which concrete `CodingAgent` module is active,
  without introducing provider-aware branching into the caller. This preserves substitutability: the two
  implementations differ in which opts keys they *require*, not in whether passing an extra key breaks the
  other.
- **Output**: `{:ok, session}` where `session` is an **opaque** term to the caller, fixed for the life of
  the run (see the session-identity note above the callback list). `AgentRunner` MUST NOT pattern-match
  on session internals or assume a subprocess is alive after this call returns — Codex's session is a
  live `Port` plus its `thread_id`, captured here and reused unchanged by every `run_turn/4` call; Claude
  Code's session (R7) is inert prep state — a Symphony-generated session UUID, the workspace path, and a
  reference to the one `ClaudeCode.MCPServer` process (a Bandit listener bound to `127.0.0.1:0`, holding
  this run's `Tracker.bind_agent_tools/0` binding and current issue in its own process state — research.md
  R6a) started for this run's lifetime — with no `claude` CLI subprocess yet, since Claude Code's headless
  mode spawns a fresh process per turn rather than one long-lived process per run.
- **Failure**: any dependency failure that prevents even attempting a turn (missing executable, invalid
  workspace cwd, MCP config generation failure, non-nil `worker_host` for Claude Code, etc.) returns
  `{:error, reason}` and MUST NOT raise — this is the seam FR-008.2 routes into the existing attempt
  failure/retry path through.

### `run_turn/4`

- **Input**: `session` — always the exact value `start_session/2` returned; `AgentRunner`'s continuation
  loop passes the same `session` value into every `run_turn/4` call for the life of one run,
  unconditionally (this is what `AgentRunner.do_run_codex_turns/8` already does today —
  `agent_runner.ex:117-126` — and is now the documented contract, not an incidental implementation
  detail). `prompt` (from `PromptBuilder` on turn 1, continuation guidance on later turns — unchanged,
  this stays in `AgentRunner`, not in the behaviour), `issue` (current `Tracker.Issue.t()`, used for
  logging/titling/tool-execution context exactly as today), `opts` — at minimum `on_message:
  (map() -> :ok)` for streaming runtime events upstream to the orchestrator (IV-004's common
  lifecycle/session observability).
- **Output**: `{:ok, turn_result}` where `turn_result` is a map that MUST include a `session_id` (may be
  `nil` only if the integration genuinely has none yet — not expected in practice, since both current
  implementations assign their session identity up front in `start_session/2`) usable for logging and the
  status dashboard's existing `session_id`/`turn_count` fields (data-model.md §5). `turn_result` MUST NOT
  be treated as carrying an updated session for the next call — there is no next-session value to carry,
  because session identity is fixed at `start_session/2` for the life of the run (see the note above this
  callback list). An implementation that needs turn-to-turn continuity state specific to its own provider
  (e.g. Claude Code's `--resume` target) captures that at `start_session/2` time, not by returning it from
  `run_turn/4`.
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
- **Output**: always `:ok`. MUST be safe to call even if the underlying resource is already gone (Codex's
  `stop_port/1` already tolerates `:erlang.port_info/1` returning `:undefined`; Claude Code's equivalent
  stops the per-run `ClaudeCode.MCPServer` Bandit listener started in `start_session/2` (R6/R6a) and
  tolerates it already being stopped/never having started, e.g. on a `start_session/2` failure before the
  listener came up — and tolerates the run's own supervision subtree already having torn it down via
  ordinary OTP linking on an abnormal exit, research.md R6a). MUST be called from an `after` block by the
  caller exactly as `AgentRunner.run_codex_turns/5` already does, so cleanup runs on every exit path
  (success, error, exception).

## Non-goals of this contract

- Does **not** standardize turn/session event names, transport framing, or tool-call wire protocol —
  those stay entirely inside each integration module (Principle VI).
- Does **not** add a 4th callback for tool binding/execution — that continues to flow through
  `Tracker.bind_agent_tools/0` + `Tracker.execute_bound_agent_tool/4`, called directly from each
  integration's own tool-call channel: `Codex.DynamicTool.execute/4` in-process from `Codex.AppServer`'s
  stdio receive loop, and `ClaudeCode.MCPServer`'s HTTP tool-call handler for Claude Code (R6/R6a) — not
  through `CodingAgent`.
- Does **not** change `AgentRunner`'s continuation policy (`continue_with_issue?/2`,
  `agent.max_turns`, tracker-state-driven continuation) — that logic reads `Tracker` directly and is
  integration-agnostic already.
