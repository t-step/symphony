defmodule SymphonyElixir.Local.Adapter do
  @moduledoc """
  Local, file-backed tracker adapter (`tracker.kind: local`).

  Every read delegates to `SymphonyElixir.Local.Store` — this module never touches the filesystem
  directly. Records are mapped 1:1 onto `Tracker.Issue.t()`; `dispatchable` is always `true`
  (research.md R11, matching the `gitlab/client.ex` precedent). `validate_config/1` distinguishes
  not-initialized, ambiguous, and corrupt/established-loss states (surfaced by `Local.Store`) from a
  structurally invalid `tracker.provider.path`, and never creates lifecycle state itself.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Local.{AgentTool, Store}
  alias SymphonyElixir.Tracker.Issue

  @default_provider_path ".symphony/local_tracker.json"

  @doc """
  Resolves `tracker.provider.path` against `workflow_dir` — the same rule `workspace.root` already
  uses (`SymphonyElixir.Config.local_workspace_root/0`): relative paths are joined to the directory
  containing the active `WORKFLOW.md`; `~` is expanded by `Path.expand/2`. `provider`'s `"path"` key
  is expected to already be defaulted/token-resolved by `Config.Schema.finalize_settings/2`.
  """
  @spec resolve_provider_path(map(), Path.t()) :: Path.t()
  def resolve_provider_path(provider, workflow_dir) when is_map(provider) and is_binary(workflow_dir) do
    path = Map.get(provider, "path") || @default_provider_path
    Path.expand(path, workflow_dir)
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_provider_path(tracker_settings.provider) do
      tracker_settings.provider
      |> resolve_provider_path(Config.workflow_dir())
      |> Store.evaluate()
      |> case do
        {:ok, _store} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    with {:ok, %{issues: issues}} <- Store.read() do
      wanted = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()
      {:ok, issues |> map_issues() |> Enum.filter(&MapSet.member?(wanted, normalize_state(&1.state)))}
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    with {:ok, %{issues: issues}} <- Store.read() do
      wanted = MapSet.new(issue_ids)
      {:ok, issues |> Enum.filter(fn {id, _record} -> MapSet.member?(wanted, id) end) |> map_issues()}
    end
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp validate_provider_path(%{"path" => path}) when is_binary(path) and path != "", do: :ok
  defp validate_provider_path(_provider), do: {:error, :invalid_local_tracker_path}

  defp map_issues(issues) when is_map(issues), do: issues |> Map.to_list() |> Enum.map(&to_issue/1)
  defp map_issues(issues) when is_list(issues), do: Enum.map(issues, &to_issue/1)

  defp to_issue({id, record}) do
    %Issue{
      id: id,
      native_ref: nil,
      identifier: Map.get(record, "identifier", id),
      title: Map.get(record, "title"),
      description: Map.get(record, "description"),
      priority: Map.get(record, "priority"),
      state: Map.get(record, "state"),
      branch_name: Map.get(record, "branch_name"),
      url: Map.get(record, "url"),
      assignee_id: Map.get(record, "assignee_id"),
      labels: normalize_list(Map.get(record, "labels")),
      blocked_by: normalize_list(Map.get(record, "blocked_by")),
      dispatchable: true,
      created_at: parse_datetime(Map.get(record, "created_at")),
      updated_at: parse_datetime(Map.get(record, "updated_at"))
    }
  end

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
