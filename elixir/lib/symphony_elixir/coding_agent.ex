defmodule SymphonyElixir.CodingAgent do
  @moduledoc """
  Behaviour for a coding-agent execution integration (e.g. Codex, Claude Code).

  `AgentRunner` calls through this seam instead of importing a specific
  integration module directly. Session identity is fixed at `start_session/2`
  and never changes for the rest of one run — `run_turn/4` reuses the exact
  session value returned by `start_session/2` on every call and does not
  return an updated one. See `specs/001-local-tracker-multi-agent/contracts/coding-agent-behaviour.md`.
  """

  alias SymphonyElixir.Config
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

  @implementations %{
    "codex" => SymphonyElixir.Codex.AppServer,
    "claude_code" => SymphonyElixir.ClaudeCode.AppServer
  }

  @doc """
  Resolves the concrete `CodingAgent` implementation module from the
  structural (restart-only) `agent_execution.kind` selection (IV-005;
  research.md R9) captured by `WorkflowStore`/`Config.structural_settings!/0`
  — mirroring `Tracker.adapter/0`'s identical resolve-from-structural-pin
  precedent. Never re-reads a live `WORKFLOW.md` edit mid-run.
  """
  @spec resolve() :: module()
  def resolve do
    {:ok, resolved} = for_kind(Config.structural_settings!().agent_execution_kind)
    resolved
  end

  @doc """
  Maps a raw `agent_execution.kind` string to its `CodingAgent` implementation
  module, or `{:error, {:unsupported_agent_execution_kind, kind}}` for any
  other value — the same shape `Tracker.adapter_for_kind/1` returns for an
  unsupported `tracker.kind`, gating an invalid selection at startup config
  validation (`Config.validate_settings/1`) before scheduling ever starts.
  """
  @spec for_kind(String.t() | nil) :: {:ok, module()} | {:error, term()}
  def for_kind(kind) do
    case Map.fetch(@implementations, kind) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unsupported_agent_execution_kind, kind}}
    end
  end
end
