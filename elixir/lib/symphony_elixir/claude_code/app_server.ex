defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc """
  Claude Code coding-agent execution integration.

  Unlike `Codex.AppServer`'s one long-lived subprocess per run, Claude Code's
  headless mode spawns a fresh `claude` CLI process per turn: turn 1 launches
  with `--session-id <uuid>`, every later turn launches with `--resume <uuid>`
  against the same Symphony-generated session UUID (research.md R7). Tracker
  agent tools are exposed to `claude` over one `ClaudeCode.MCPServer` HTTP
  listener started once for the run's lifetime (`start_session/2`) and reused
  by every turn's subprocess, not restarted per turn (research.md R6/R6a).
  """

  @behaviour SymphonyElixir.CodingAgent

  require Logger
  alias SymphonyElixir.ClaudeCode.MCPServer
  alias SymphonyElixir.{Config, PathSafety, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @line_bytes 1_048_576
  @allowed_env_names ~w(PATH HOME USER SHELL LANG LC_ALL LC_CTYPE TERM TMPDIR ANTHROPIC_API_KEY)

  @type session :: %{
          session_id: String.t(),
          workspace: Path.t(),
          mcp_server: MCPServer.start_result(),
          mcp_config_path: Path.t(),
          turn_state: :atomics.atomics_ref()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- reject_worker_host(worker_host),
         {:ok, issue} <- fetch_issue(opts),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace) do
      start_session_resources(expanded_workspace, issue)
    end
  end

  @spec run_turn(session(), String.t(), Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session_id: session_id, workspace: workspace, mcp_config_path: mcp_config_path, turn_state: turn_state},
        prompt,
        %Issue{} = issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    first_turn? = :atomics.exchange(turn_state, 1, 1) == 0

    case start_port(workspace, prompt, session_id, first_turn?, mcp_config_path) do
      {:ok, port} ->
        Logger.info("Claude Code turn started for #{issue_context(issue)} session_id=#{session_id}")

        try do
          await_turn_completion(port, on_message, session_id)
        after
          close_port(port)
        end

      {:error, reason} ->
        Logger.error("Claude Code turn failed to launch for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{session_id: session_id, reason: reason})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{mcp_server: mcp_server, mcp_config_path: mcp_config_path}) do
    MCPServer.stop(mcp_server)
    File.rm(mcp_config_path)
    :ok
  end

  defp reject_worker_host(nil), do: :ok
  defp reject_worker_host(_worker_host), do: {:error, :remote_worker_not_supported}

  defp fetch_issue(opts) do
    case Keyword.fetch(opts, :issue) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      _ -> {:error, :issue_required}
    end
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp start_session_resources(workspace, issue) do
    dynamic_tool_binding = Tracker.bind_agent_tools()

    with {:ok, mcp_server} <- MCPServer.start_link(tracker_binding: dynamic_tool_binding, issue: issue) do
      case write_mcp_config(mcp_server) do
        {:ok, mcp_config_path} ->
          {:ok,
           %{
             session_id: Ecto.UUID.generate(),
             workspace: workspace,
             mcp_server: mcp_server,
             mcp_config_path: mcp_config_path,
             turn_state: :atomics.new(1, [])
           }}

        {:error, reason} ->
          MCPServer.stop(mcp_server)
          {:error, reason}
      end
    end
  end

  defp write_mcp_config(%{port: port, token: token}) do
    path = Path.join(System.tmp_dir!(), "symphony-claude-mcp-#{System.unique_integer([:positive])}.json")

    contents =
      Jason.encode!(%{
        "mcpServers" => %{
          "symphony_tracker" => %{
            "type" => "http",
            "url" => "http://127.0.0.1:#{port}/mcp/#{token}"
          }
        }
      })

    case File.write(path, contents) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:mcp_config_write_failed, reason}}
    end
  end

  defp start_port(workspace, prompt, session_id, first_turn?, mcp_config_path) do
    with {:ok, [executable | base_args]} <- resolve_command() do
      session_args = if first_turn?, do: ["--session-id", session_id], else: ["--resume", session_id]

      args =
        base_args ++
          ["-p", prompt] ++
          session_args ++
          [
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--mcp-config",
            mcp_config_path
          ]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: claude_subprocess_env(),
            line: @line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp resolve_command do
    case Config.settings!().claude_code.command |> String.split() do
      [] ->
        {:error, :claude_command_blank}

      [name | args] ->
        case System.find_executable(name) do
          nil -> {:error, {:claude_executable_not_found, name}}
          executable -> {:ok, [executable | args]}
        end
    end
  end

  defp claude_subprocess_env do
    System.get_env()
    |> Map.keys()
    |> Enum.reject(&(&1 in @allowed_env_names))
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp await_turn_completion(port, on_message, session_id) do
    receive_loop(port, on_message, session_id, :bootstrap, "")
  end

  defp receive_loop(port, on_message, session_id, phase, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_incoming(port, on_message, session_id, phase, pending_line <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, session_id, phase, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      phase_timeout_ms(phase) ->
        {:error, :turn_timeout}
    end
  end

  defp phase_timeout_ms(:bootstrap), do: Config.settings!().claude_code.read_timeout_ms
  defp phase_timeout_ms(:turn), do: Config.settings!().claude_code.turn_timeout_ms

  defp handle_incoming(port, on_message, session_id, _phase, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        emit_message(on_message, :session_started, %{session_id: session_id, raw: payload})
        receive_loop(port, on_message, session_id, :turn, "")

      {:ok, %{"type" => "result"} = payload} ->
        handle_result(payload, on_message, session_id)

      {:ok, %{"type" => type} = payload} when is_binary(type) ->
        emit_message(on_message, :notification, %{session_id: session_id, raw: payload})
        receive_loop(port, on_message, session_id, :turn, "")

      {:ok, _payload} ->
        receive_loop(port, on_message, session_id, :turn, "")

      {:error, _reason} ->
        log_non_json_stream_line(line)
        receive_loop(port, on_message, session_id, :turn, "")
    end
  end

  defp handle_result(%{"is_error" => false} = payload, on_message, session_id) do
    emit_message(on_message, :turn_completed, %{session_id: session_id, raw: payload})
    {:ok, %{session_id: session_id, result: Map.get(payload, "result"), raw: payload}}
  end

  defp handle_result(%{"is_error" => true} = payload, on_message, session_id) do
    emit_message(on_message, :turn_failed, %{session_id: session_id, raw: payload})
    {:error, {:turn_failed, payload}}
  end

  defp handle_result(payload, on_message, session_id) do
    emit_message(on_message, :turn_failed, %{session_id: session_id, raw: payload})
    {:error, {:malformed_result, payload}}
  end

  # Erlang `Port.close/1` disconnects the port but does not guarantee the underlying OS
  # process exits (a well-known `:spawn_executable` limitation) — without an explicit kill,
  # a turn that times out or crashes mid-stream leaves its `claude` subprocess running for
  # the lifetime of whatever it was doing (e.g. a `sleep`), instead of terminating cleanly.
  defp close_port(port) when is_port(port) do
    kill_os_process(port)

    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp kill_os_process(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = details |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp log_non_json_stream_line(data) do
    text = String.trim(data)

    if text != "" do
      Logger.debug("Claude Code turn stream output: #{String.slice(text, 0, 1_000)}")
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
