defmodule SymphonyElixir.ClaudeCode.MCPServer do
  @moduledoc """
  Per-run MCP-over-HTTP tool server for the Claude Code coding-agent integration.

  Hosts one `Bandit` HTTP listener, bound to `127.0.0.1:0`, for the lifetime of one
  coding-agent run. `ClaudeCode.AppServer.start_session/2` starts it once, before the
  first turn, and `stop_session/1` stops it once, after the run's last turn — reused
  across every turn of that run, never per-turn (research.md R6a). It holds the run's
  `Tracker.bind_agent_tools/0` binding and current `Tracker.Issue.t()` as this
  listener's own Plug init state: there is no lookup table, registry, or other
  shared/global state, so an incoming request can only ever reach the one run's
  binding this listener was started with.

  Implements just enough of the MCP Streamable HTTP transport (JSON-RPC 2.0 over a
  single POST endpoint, `POST /mcp/<token>`) for `claude`'s MCP client to initialize,
  list tools, and call the bound tracker adapter's tool(s) — no server-initiated SSE
  stream, since tool calls here never need to push unsolicited notifications to the
  client. The `<token>` path segment is a per-run, cryptographically-random bearer
  token checked on every request before it reaches `Tracker.execute_bound_agent_tool/4`
  (research.md R6a) — defense in depth on top of the loopback-only bind, since the
  ephemeral port itself is visible to any other local process.
  """

  @behaviour Plug

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  @token_bytes 32
  @jsonrpc_version "2.0"
  @server_name "symphony_tracker"
  @server_version "1.0.0"
  @default_protocol_version "2025-06-18"

  @type start_result :: %{pid: pid(), port: :inet.port_number(), token: String.t()}
  @type start_opts :: [
          tracker_binding: map(),
          issue: Issue.t(),
          ip: :inet.socket_address(),
          port: :inet.port_number(),
          token: String.t()
        ]

  @doc """
  Starts one per-run MCP HTTP listener bound to `127.0.0.1:0` (override via `:ip`/
  `:port`, e.g. for tests). Returns the listener's pid, the port it actually bound,
  and the per-run bearer token a caller must embed in the tool-call URL path
  (`/mcp/<token>`) it hands to `claude` via `--mcp-config`. A token is generated when
  `:token` is not given.
  """
  @spec start_link(start_opts()) :: {:ok, start_result()} | {:error, term()}
  def start_link(opts) do
    tracker_binding = Keyword.fetch!(opts, :tracker_binding)
    issue = Keyword.fetch!(opts, :issue)
    token = Keyword.get_lazy(opts, :token, &generate_token/0)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)

    plug_state = %{tracker_binding: tracker_binding, issue: issue, token: token}

    case Bandit.start_link(plug: {__MODULE__, plug_state}, ip: ip, port: port, startup_log: false) do
      {:ok, pid} -> {:ok, %{pid: pid, port: bound_port(pid), token: token}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a listener previously started by `start_link/1`. Accepts either the pid or
  the map `start_link/1` returned. Always returns `:ok`, tolerating a listener that
  is already stopped (mirrors `Codex.AppServer.stop_port/1`'s tolerance for an
  already-gone `Port`).
  """
  @spec stop(pid() | start_result()) :: :ok
  def stop(%{pid: pid}), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @spec bound_port(pid()) :: :inet.port_number()
  def bound_port(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  ## Plug callbacks

  @impl Plug
  def init(plug_state), do: plug_state

  @impl Plug
  def call(conn, plug_state) do
    case {conn.method, conn.path_info} do
      {"POST", ["mcp", token]} -> handle_authorized(conn, plug_state, token)
      {"GET", ["mcp", _token]} -> send_status(conn, 405, %{"error" => "method_not_allowed"})
      _ -> send_status(conn, 404, %{"error" => "not_found"})
    end
  end

  defp handle_authorized(conn, %{token: expected_token} = plug_state, token) do
    if authorized?(token, expected_token) do
      case Plug.Conn.read_body(conn) do
        {:ok, body, conn} -> dispatch_body(conn, plug_state, body)
        _ -> send_status(conn, 400, %{"error" => "invalid_request"})
      end
    else
      send_status(conn, 401, %{"error" => "unauthorized"})
    end
  end

  defp authorized?(token, expected_token) do
    byte_size(token) == byte_size(expected_token) and Plug.Crypto.secure_compare(token, expected_token)
  end

  defp dispatch_body(conn, plug_state, body) do
    case Jason.decode(body) do
      {:ok, message} -> handle_message(conn, plug_state, message)
      {:error, _reason} -> send_json_rpc_error(conn, nil, -32_700, "Parse error")
    end
  end

  defp handle_message(conn, _plug_state, %{"method" => "notifications/initialized"}) do
    send_status(conn, 202, nil)
  end

  defp handle_message(conn, _plug_state, %{"id" => id, "method" => "initialize"} = message) do
    protocol_version =
      message |> Map.get("params", %{}) |> Map.get("protocolVersion", @default_protocol_version)

    send_json_rpc_result(conn, id, %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => @server_version}
    })
  end

  defp handle_message(conn, %{tracker_binding: binding}, %{"id" => id, "method" => "tools/list"}) do
    send_json_rpc_result(conn, id, %{"tools" => binding.tool_specs})
  end

  defp handle_message(conn, %{tracker_binding: binding, issue: issue}, %{
         "id" => id,
         "method" => "tools/call",
         "params" => %{"name" => name} = params
       }) do
    arguments = Map.get(params, "arguments", %{})
    result = Tracker.execute_bound_agent_tool(binding, name, arguments, issue: issue)
    send_json_rpc_result(conn, id, tool_call_result(result))
  end

  defp handle_message(conn, _plug_state, %{"id" => id}) do
    send_json_rpc_error(conn, id, -32_601, "Method not found")
  end

  defp handle_message(conn, _plug_state, %{"method" => _method}) do
    send_status(conn, 202, nil)
  end

  defp handle_message(conn, _plug_state, _message) do
    send_status(conn, 400, %{"error" => "invalid_request"})
  end

  defp tool_call_result(%{"success" => success, "output" => output}) do
    %{"content" => [%{"type" => "text", "text" => output}], "isError" => not success}
  end

  defp send_json_rpc_result(conn, id, result) do
    send_json(conn, 200, %{"jsonrpc" => @jsonrpc_version, "id" => id, "result" => result})
  end

  defp send_json_rpc_error(conn, id, code, message) do
    send_json(conn, 200, %{
      "jsonrpc" => @jsonrpc_version,
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp send_status(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")
  defp send_status(conn, status, payload), do: send_json(conn, status, payload)

  defp send_json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end

  defp generate_token do
    Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
  end
end
