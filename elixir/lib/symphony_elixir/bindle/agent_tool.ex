defmodule SymphonyElixir.Bindle.AgentTool do
  @moduledoc """
  Agent-invoked task-completion tool for the Bindle-backed tracker (`tracker.kind: bindle`).

  Exposes exactly one tool, scoped to the ONE Bindle task bound to the current coding-agent session
  (`opts[:issue]`, threaded through `Tracker.execute_bound_agent_tool/4` from the Claude Code MCP tool
  handler) — it cannot target an arbitrary task id, since its `inputSchema` declares no task-id
  parameter at all for a model-supplied argument to override.

  Calls only `bindle work done <id>` for that one task, then a best-effort `bindle work publish`
  (`002-bindle-integration` FR-013 as corrected; this feature's FR-025–FR-027). Infers nothing from
  mechanical evidence — fires only on the agent's own explicit tool call. Exposes no milestone
  review/acceptance path, and shares no code path with the orchestrator-owned
  `SymphonyElixir.Bindle.Adapter.acquire_issue/2`/`release_issue/2` seam beyond the `Bindle.Cli`
  wrapper module both happen to call into.
  """

  alias SymphonyElixir.Bindle.Adapter
  alias SymphonyElixir.Tracker.Issue

  @tool_name "bindle_mark_task_done"
  @description "Mark the current Bindle task done. Only the task bound to this session can be targeted."
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{}
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    [%{"name" => @tool_name, "description" => @description, "inputSchema" => @input_schema}]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, _arguments, opts), do: execute_mark_done(opts)
  def execute(tool, _arguments, _opts), do: unsupported_tool_response(tool)

  defp execute_mark_done(opts) do
    case bound_issue_id(opts) do
      {:ok, issue_id} -> do_mark_done(issue_id)
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp do_mark_done(issue_id) do
    provider = SymphonyElixir.Config.settings!().tracker.provider
    repo_path = Adapter.resolve_repo_path(provider)
    bindle_bin = Adapter.resolve_bindle_bin(provider)

    case cli_module().done(repo_path, bindle_bin, issue_id) do
      {:ok, output} ->
        success_response(issue_id, output, publish(repo_path, bindle_bin))

      {:error, reason} ->
        failure_response(tool_error_payload({:done_failed, reason}))
    end
  end

  # Best-effort projection refresh after a successful `done` — Bindle has no auto-publish hook on any
  # lifecycle-mutating command. A publish failure MUST NOT be treated as a `done` failure and MUST NOT
  # trigger a retry of `done` (which would return a spurious `not_open` for a mutation that already
  # genuinely succeeded, per `mark_done/1`'s `status = 'open'` guard) — it is surfaced as a distinct
  # field in this tool's own result payload instead (FR-027).
  defp publish(repo_path, bindle_bin) do
    case cli_module().publish(repo_path, bindle_bin) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bound_issue_id(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :no_bound_issue}
    end
  end

  defp cli_module do
    Application.get_env(:symphony_elixir, :bindle_cli_module, SymphonyElixir.Bindle.Cli)
  end

  defp success_response(issue_id, done_output, :ok) do
    dynamic_tool_response(true, encode_payload(%{"id" => issue_id, "done" => done_output, "publish" => "ok"}))
  end

  defp success_response(issue_id, done_output, {:error, publish_reason}) do
    dynamic_tool_response(
      true,
      encode_payload(%{
        "id" => issue_id,
        "done" => done_output,
        "publish" => "failed",
        "publish_error" => inspect(publish_reason)
      })
    )
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload), do: Jason.encode!(payload, pretty: true)

  defp tool_error_payload(:no_bound_issue) do
    %{"error" => %{"message" => "No bound issue for this session; #{@tool_name} cannot target a task."}}
  end

  defp tool_error_payload({:done_failed, reason}) do
    %{"error" => %{"message" => "bindle work done failed.", "reason" => inspect(reason)}}
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => [@tool_name]
      }
    })
  end
end
