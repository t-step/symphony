# Contract: New `WORKFLOW.md` Front-Matter Fields

`WORKFLOW.md` is Symphony's one runtime configuration surface (spec Assumptions). This documents the
additive fields this feature introduces, in the same "cheat sheet" style as `SPEC.md` §6.4, for operators
and for the `Config.Schema` implementation.

## New fields

- `tracker.kind: local` — selects the local work-tracking source (contracts/local-tracker-adapter.md).
  Existing `tracker.kind` values (`github`, `gitlab`, `jira`, `linear`, `asana`, `memory`) are unchanged.
- `tracker.provider.path`: string, default `.symphony/local_tracker.json` — only meaningful when
  `tracker.kind: local`.
- `agent_execution.kind`: string, default `"codex"` (absent = `"codex"`), `"codex" | "claude_code"` —
  selects the coding-agent execution integration (contracts/coding-agent-behaviour.md).
- `claude_code.*` — sibling embed to the existing `codex.*` embed, same shape class (command/launch
  settings, timeouts, an unattended-approval-mode setting). Exact field list is finalized during
  implementation once research.md R5/R8's confidence-flagged CLI details are re-verified against the
  targeted Claude Code CLI version, mirroring how `SPEC.md` §10 already treats "the targeted Codex
  app-server version" (not this spec) as the protocol source of truth. At minimum, mirrors `codex.command`
  with a `claude_code.command` default (the `claude` CLI invocation) and a
  `claude_code.turn_timeout_ms`/`read_timeout_ms` pair analogous to `codex.turn_timeout_ms`/
  `codex.read_timeout_ms`.

## Structural vs. dynamic reload (IV-005)

`tracker.kind` and `agent_execution.kind` are **structural** — read once at process start, changes take
effect only on the next restart. Every other field introduced here (`tracker.provider.path`,
`claude_code.*` runtime settings) follows the **same dynamic-reload class as its sibling today**:
`tracker.provider.*` reloads exactly as every other tracker's `tracker.provider.*` already does (a
tracker-provider setting, not a tracker*-selection*), and `claude_code.*` reloads exactly as `codex.*`
already does (a coding-agent *runtime* setting, not an execution-integration *selection*). Only the two
`kind` selector fields are restart-only; this is the smallest possible carve-out consistent with IV-005
as already written in the frozen spec.

## Validation

Both new `kind` values plug into the existing per-tick and startup dispatch preflight validation
(`SPEC.md` §6.3): `tracker.kind: local` is validated by `Local.Adapter.validate_config/1`
(contracts/local-tracker-adapter.md); `agent_execution.kind: claude_code` is validated the same way
`codex.command` is validated today — presence/non-blankness of `claude_code.command` (or its resolved
default) before the scheduling loop starts, and re-validated per dispatch tick per §6.3.

## Backward compatibility (FR-006, SC-003)

A `WORKFLOW.md` that specifies neither new field parses and behaves exactly as it does today: `tracker.kind`
must still be one of the pre-existing supported values (no default — `SPEC.md` §6.4 already requires
`tracker.kind` to be present), and `agent_execution.kind` defaults to `"codex"`, so an existing Codex +
hosted-tracker deployment observes zero behavioral change.
