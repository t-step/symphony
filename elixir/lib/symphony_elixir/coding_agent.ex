defmodule SymphonyElixir.CodingAgent do
  @moduledoc """
  Behaviour for a coding-agent execution integration (e.g. Codex, Claude Code).

  `AgentRunner` calls through this seam instead of importing a specific
  integration module directly. Session identity is fixed at `start_session/2`
  and never changes for the rest of one run — `run_turn/4` reuses the exact
  session value returned by `start_session/2` on every call and does not
  return an updated one. See `specs/001-local-tracker-multi-agent/contracts/coding-agent-behaviour.md`.
  """

  alias SymphonyElixir.Tracker.Issue

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session :: term()} | {:error, reason :: term()}

  @callback run_turn(
              session :: term(),
              prompt :: String.t(),
              issue :: Issue.t(),
              opts :: keyword()
            ) :: {:ok, turn_result :: map()} | {:error, reason :: term()}

  @callback stop_session(session :: term()) :: :ok
end
