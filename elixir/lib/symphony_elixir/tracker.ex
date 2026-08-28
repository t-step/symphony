defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "bindle" => SymphonyElixir.Bindle.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "local" => SymphonyElixir.Local.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback acquire_issue(Issue.t(), keyword()) :: :ok | {:error, term()}
  @callback release_issue(issue_id :: String.t(), keyword()) :: :ok | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1,
                      acquire_issue: 2,
                      release_issue: 2

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @doc """
  Calls the active adapter's optional real-time acquisition seam, when it implements one (a
  durable-claim-aware tracker such as Bindle). A complete no-op (`:ok`) for every adapter that does not
  implement `acquire_issue/2` — the projection's own admission fact remains sufficient proof of eligibility
  for those adapters.
  """
  @spec acquire_issue(Issue.t(), keyword()) :: :ok | {:error, term()}
  def acquire_issue(%Issue{} = issue, opts \\ []) do
    call_optional_seam(:acquire_issue, [issue, opts])
  end

  @doc """
  Calls the active adapter's optional real-time release seam, when it implements one. A complete no-op
  (`:ok`) for every adapter that does not implement `release_issue/2`.
  """
  @spec release_issue(String.t(), keyword()) :: :ok | {:error, term()}
  def release_issue(issue_id, opts \\ []) when is_binary(issue_id) do
    call_optional_seam(:release_issue, [issue_id, opts])
  end

  defp call_optional_seam(function, args) do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, function, length(args)) do
      apply(adapter, function, args)
    else
      :ok
    end
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    bound_adapter = adapter()

    %{
      adapter: bound_adapter,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(bound_adapter),
      secret_environment_names: adapter_secret_environment_names(bound_adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    execute_agent_tool_with_adapter(
      adapter,
      tool,
      arguments,
      Keyword.put(opts, :tracker_settings, tracker_settings)
    )
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @doc """
  Resolves the active tracker adapter module from the structural (restart-only)
  `tracker.kind` selection (IV-005; research.md R9), not from a live-reloaded
  read of `WORKFLOW.md`.
  """
  @spec adapter() :: module()
  def adapter do
    {:ok, resolved_adapter} = adapter_for_kind(Config.structural_settings!().tracker_kind)
    resolved_adapter
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
