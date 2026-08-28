defmodule SymphonyElixir.Bindle.Adapter do
  @moduledoc """
  Bindle-backed tracker adapter (`tracker.kind: bindle`).

  Reads only Bindle's externally-published, read-only, schema-versioned `symphony-projection.sqlite3`
  artifact via `SymphonyElixir.Bindle.Projection` — never Bindle's canonical ledger file, never a raw
  database write. `repo_path` defaults to `Config.workflow_dir()`; the projection `path` defaults
  relative to `repo_path`, never independently relative to `workflow_dir()` (research.md R15), so the
  read side and the `bindle` CLI's write side cannot silently target different repositories.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Bindle.{AgentTool, Cli, Owner, Projection}
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_projection_relative_path ".bindle-work/symphony-projection.sqlite3"
  @default_bindle_bin "bindle"
  @default_owner_id_relative_path ".symphony/bindle_owner_id"

  @doc """
  Resolves the Bindle repository root the CLI is invoked against — `tracker.provider.repo_path` if
  set, otherwise `Config.workflow_dir()` (the common-case assumption that a Bindle-backed deployment's
  target repository and Symphony's own workflow repository are the same one).
  """
  @spec resolve_repo_path(map()) :: Path.t()
  def resolve_repo_path(provider) when is_map(provider) do
    case Map.get(provider, "repo_path") do
      path when is_binary(path) and path != "" -> Path.expand(path, Config.workflow_dir())
      _ -> Config.workflow_dir()
    end
  end

  @doc """
  Resolves the published projection artifact's path — `tracker.provider.path` if set, otherwise
  `<repo_path>/.bindle-work/symphony-projection.sqlite3`, resolved relative to `repo_path` (never
  independently relative to `workflow_dir()`).
  """
  @spec resolve_projection_path(map()) :: Path.t()
  def resolve_projection_path(provider) when is_map(provider) do
    repo_path = resolve_repo_path(provider)

    case Map.get(provider, "path") do
      path when is_binary(path) and path != "" -> Path.expand(path, repo_path)
      _ -> Path.join(repo_path, @default_projection_relative_path)
    end
  end

  @doc "Resolves the `bindle` CLI binary name/path — defaults to `\"bindle\"` (resolved via `$PATH`)."
  @spec resolve_bindle_bin(map()) :: String.t()
  def resolve_bindle_bin(provider) when is_map(provider) do
    case Map.get(provider, "bindle_bin") do
      bin when is_binary(bin) and bin != "" -> bin
      _ -> @default_bindle_bin
    end
  end

  @doc """
  Resolves the persisted owner-identity file's path — Symphony-owned deployment state, deliberately
  independent of `repo_path` (never placed inside Bindle's own `.bindle-work/` directory).
  """
  @spec resolve_owner_id_path(map()) :: Path.t()
  def resolve_owner_id_path(provider) when is_map(provider) do
    case Map.get(provider, "owner_id_path") do
      path when is_binary(path) and path != "" -> Path.expand(path, Config.workflow_dir())
      _ -> Path.join(Config.workflow_dir(), @default_owner_id_relative_path)
    end
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    Projection.open_and_validate(resolve_projection_path(tracker_settings.provider))
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    Projection.fetch_by_states(projection_path(), state_names)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    Projection.fetch_by_ids(projection_path(), issue_ids)
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  @doc """
  The one narrow, agent-invoked, session-scoped task-completion tool this feature restores
  (`002-bindle-integration` FR-013 as corrected, FR-025/FR-026) — never a milestone/evidence/
  dependency capability, never an orchestrator-owned API.
  """
  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @doc """
  Real-time claim arbitration seam (`002-bindle-integration` FR-015). Calls only `bindle work claim`
  (FR-009) — never reads or writes any lifecycle-state field, never a raw database mutation (FR-018).
  Scoped exclusively to the orchestrator-owned claim/release seam; shares no code path with
  `SymphonyElixir.Bindle.AgentTool`'s `done`/`publish` calls beyond this same `Cli` wrapper module.
  """
  @spec acquire_issue(Issue.t(), keyword()) :: :ok | {:error, term()}
  def acquire_issue(%Issue{id: id}, _opts \\ []) when is_binary(id) do
    provider = Config.settings!().tracker.provider

    with {:ok, owner} <- Owner.id(resolve_owner_id_path(provider)),
         {:ok, _output} <-
           cli_module().claim(resolve_repo_path(provider), resolve_bindle_bin(provider), id, owner) do
      :ok
    end
  end

  @doc """
  Real-time claim release seam. Takes only the issue's stable id, not a full `Issue.t()` — at least
  one genuine orchestrator release call site has only an id available (FR-020). Calls only
  `bindle work release`.
  """
  @spec release_issue(String.t(), keyword()) :: :ok | {:error, term()}
  def release_issue(issue_id, _opts \\ []) when is_binary(issue_id) do
    provider = Config.settings!().tracker.provider

    with {:ok, owner} <- Owner.id(resolve_owner_id_path(provider)),
         {:ok, _output} <-
           cli_module().release(resolve_repo_path(provider), resolve_bindle_bin(provider), issue_id, owner) do
      :ok
    end
  end

  defp cli_module do
    Application.get_env(:symphony_elixir, :bindle_cli_module, Cli)
  end

  defp projection_path do
    resolve_projection_path(Config.settings!().tracker.provider)
  end
end
