defmodule SymphonyElixir.Local.AgentTool do
  @moduledoc """
  Agent-invoked lifecycle tool for the local, file-backed tracker (`tracker.kind: local`).

  Exposes exactly one tool, `local_tracker_set_state`, scoped to the issue bound to the current
  coding-agent session (`opts[:issue]`, threaded through `Tracker.execute_bound_agent_tool/4` from
  `Codex.DynamicTool.execute/4`/the Claude Code MCP tool handler) — it cannot target an arbitrary
  `id`. Mutates only that issue's `state` via `Local.Store.set_issue_state/3`.
  """

  alias SymphonyElixir.Local.Store
  alias SymphonyElixir.Tracker.Issue

  @tool_name "local_tracker_set_state"
  @description "Set the current work item's state in the local, file-backed tracker."
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["state"],
    "properties" => %{
      "state" => %{
        "type" => "string",
        "description" => "New provider-native state name for the current work item."
      }
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    [%{"name" => @tool_name, "description" => @description, "inputSchema" => @input_schema}]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool_name, arguments, opts), do: execute_set_state(arguments, opts)
  def execute(tool, _arguments, _opts), do: unsupported_tool_response(tool)

  defp execute_set_state(arguments, opts) do
    with {:ok, new_state} <- normalize_arguments(arguments),
         {:ok, issue_id} <- bound_issue_id(opts) do
      case Store.set_issue_state(issue_id, new_state) do
        {:ok, record} -> success_response(record)
        {:error, reason} -> failure_response(tool_error_payload(reason))
      end
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_arguments(%{"state" => state}) when is_binary(state) and state != "", do: {:ok, state}
  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp bound_issue_id(opts) do
    case Keyword.get(opts, :issue) do
      %Issue{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :no_bound_issue}
    end
  end

  defp success_response(record) do
    output = encode_payload(record)
    dynamic_tool_response(true, output)
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

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`local_tracker_set_state` expects an object with a non-empty `state` string."}}
  end

  defp tool_error_payload(:no_bound_issue) do
    %{"error" => %{"message" => "No bound issue for this session; local_tracker_set_state cannot target an issue."}}
  end

  defp tool_error_payload(:issue_not_found) do
    %{"error" => %{"message" => "The bound issue is no longer present in the local tracker store."}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "local_tracker_set_state failed.", "reason" => inspect(reason)}}
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
