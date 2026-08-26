defmodule SymphonyElixir.ClaudeCode.MCPServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaudeCode.MCPServer
  alias SymphonyElixir.Tracker.Issue

  defmodule FakeAdapter do
    def execute_agent_tool("record_state", %{"state" => state}, opts) do
      issue = Keyword.fetch!(opts, :issue)
      tracker_settings = Keyword.fetch!(opts, :tracker_settings)
      Agent.update(tracker_settings.recorder, &[{issue.id, state} | &1])
      %{"success" => true, "output" => "recorded"}
    end

    def execute_agent_tool(tool, _arguments, _opts) do
      %{"success" => false, "output" => "unsupported tool: #{tool}"}
    end
  end

  @tool_specs [
    %{
      "name" => "record_state",
      "description" => "Records the run's bound issue state for test assertions.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"state" => %{"type" => "string"}},
        "required" => ["state"]
      }
    }
  ]

  setup do
    {:ok, recorder} = Agent.start_link(fn -> [] end)
    issue = %Issue{id: "ISSUE-A-#{System.unique_integer([:positive])}"}
    {:ok, server} = MCPServer.start_link(tracker_binding: tracker_binding(recorder), issue: issue)
    on_exit(fn -> MCPServer.stop(server) end)

    %{server: server, recorder: recorder, issue: issue}
  end

  test "starts a loopback listener on an ephemeral port", %{server: server} do
    assert server.port > 0
    assert MCPServer.bound_port(server.pid) == server.port
  end

  test "start_link/1 surfaces a listener startup failure instead of raising", %{server: server, recorder: recorder} do
    issue = %Issue{id: "ISSUE-CONFLICT"}

    assert {:error, _reason} =
             MCPServer.start_link(tracker_binding: tracker_binding(recorder), issue: issue, port: server.port)
  end

  describe "initialize" do
    test "returns capabilities and echoes the requested protocol version", %{server: server} do
      response =
        rpc(server, %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2099-01-01"}
        })

      assert response.status == 200
      assert response.body["id"] == 1
      assert response.body["result"]["protocolVersion"] == "2099-01-01"
      assert response.body["result"]["capabilities"] == %{"tools" => %{}}
      assert response.body["result"]["serverInfo"]["name"] == "symphony_tracker"
    end

    test "defaults the protocol version when the client omits it", %{server: server} do
      response = rpc(server, %{"jsonrpc" => "2.0", "id" => 2, "method" => "initialize"})
      assert response.body["result"]["protocolVersion"] == "2025-06-18"
    end
  end

  test "notifications/initialized is acknowledged with no JSON-RPC envelope", %{server: server} do
    response = rpc(server, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response.status == 202
  end

  test "tools/list advertises the bound adapter's tool specs", %{server: server} do
    response = rpc(server, %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"})
    assert response.body["result"]["tools"] == @tool_specs
  end

  describe "tools/call" do
    test "dispatches to the bound tracker adapter with the run's bound issue", %{
      server: server,
      recorder: recorder,
      issue: issue
    } do
      response =
        rpc(server, %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "record_state", "arguments" => %{"state" => "in_progress"}}
        })

      assert response.body["result"]["isError"] == false
      assert response.body["result"]["content"] == [%{"type" => "text", "text" => "recorded"}]
      assert Agent.get(recorder, & &1) == [{issue.id, "in_progress"}]
    end

    test "surfaces an unsupported tool as an MCP tool-call error", %{server: server} do
      response =
        rpc(server, %{
          "jsonrpc" => "2.0",
          "id" => 5,
          "method" => "tools/call",
          "params" => %{"name" => "not_a_real_tool", "arguments" => %{}}
        })

      assert response.body["result"]["isError"] == true
    end
  end

  test "an unrecognized method with an id returns a JSON-RPC method-not-found error", %{server: server} do
    response = rpc(server, %{"jsonrpc" => "2.0", "id" => 6, "method" => "not/a/method"})
    assert response.body["error"]["code"] == -32_601
  end

  test "an unrecognized notification (no id) is acknowledged with no body", %{server: server} do
    response = rpc(server, %{"jsonrpc" => "2.0", "method" => "some/notification"})
    assert response.status == 202
  end

  test "malformed JSON is rejected as a JSON-RPC parse error", %{server: server} do
    response = Req.post!(mcp_url(server), body: "{not json", headers: [{"content-type", "application/json"}])
    assert response.status == 200
    assert response.body["error"]["code"] == -32_700
  end

  test "a decoded message with no method is rejected as an invalid request", %{server: server} do
    response = rpc(server, %{"jsonrpc" => "2.0"})
    assert response.status == 400
    assert response.body["error"] == "invalid_request"
  end

  test "a request body too large to read in one pass is rejected as an invalid request", %{server: server} do
    oversized_body = Jason.encode!(%{"padding" => String.duplicate("a", 8_000_001)})
    response = Req.post!(mcp_url(server), body: oversized_body, headers: [{"content-type", "application/json"}])
    assert response.status == 400
    assert response.body["error"] == "invalid_request"
  end

  describe "authentication" do
    test "rejects a wrong token", %{server: server} do
      response = rpc(server, server.token <> "-wrong", %{"jsonrpc" => "2.0", "id" => 7, "method" => "tools/list"})
      assert response.status == 401
      assert response.body["error"] == "unauthorized"
    end

    test "rejects a request with no token path segment", %{server: server} do
      response = Req.post!("http://127.0.0.1:#{server.port}/mcp", json: %{"jsonrpc" => "2.0", "method" => "tools/list"})
      assert response.status == 404
    end

    test "GET is rejected regardless of token validity (no SSE support)", %{server: server} do
      response = Req.get!(mcp_url(server))
      assert response.status == 405
      assert response.body["error"] == "method_not_allowed"

      bad_token_response = Req.get!(mcp_url(server, server.token <> "-wrong"))
      assert bad_token_response.status == 405
    end

    test "an unrelated path returns not found", %{server: server} do
      response = Req.get!("http://127.0.0.1:#{server.port}/unknown")
      assert response.status == 404
    end
  end

  describe "cross-run isolation" do
    setup %{recorder: recorder_a} do
      recorder_b_start = Agent.start_link(fn -> [] end)
      {:ok, recorder_b} = recorder_b_start
      issue_b = %Issue{id: "ISSUE-B-#{System.unique_integer([:positive])}"}
      {:ok, server_b} = MCPServer.start_link(tracker_binding: tracker_binding(recorder_b), issue: issue_b)
      on_exit(fn -> MCPServer.stop(server_b) end)

      refute recorder_b == recorder_a
      %{server_b: server_b, recorder_b: recorder_b, issue_b: issue_b}
    end

    test "two concurrently-started instances bind distinct ports and tokens", %{server: server_a, server_b: server_b} do
      refute server_a.port == server_b.port
      refute server_a.token == server_b.token
    end

    test "run A's token against run B's port is rejected", %{server: server_a, server_b: server_b} do
      response = rpc(server_b, server_a.token, %{"jsonrpc" => "2.0", "id" => 8, "method" => "tools/list"})
      assert response.status == 401
    end

    test "run B's token against run A's port is rejected", %{server: server_a, server_b: server_b} do
      response = rpc(server_a, server_b.token, %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"})
      assert response.status == 401
    end

    test "each run's tool call lands only on its own bound issue", %{
      server: server_a,
      issue: issue_a,
      recorder: recorder_a,
      server_b: server_b,
      issue_b: issue_b,
      recorder_b: recorder_b
    } do
      call = fn server, state ->
        rpc(server, %{
          "jsonrpc" => "2.0",
          "id" => 10,
          "method" => "tools/call",
          "params" => %{"name" => "record_state", "arguments" => %{"state" => state}}
        })
      end

      assert call.(server_a, "run-a-state").body["result"]["isError"] == false
      assert call.(server_b, "run-b-state").body["result"]["isError"] == false

      assert Agent.get(recorder_a, & &1) == [{issue_a.id, "run-a-state"}]
      assert Agent.get(recorder_b, & &1) == [{issue_b.id, "run-b-state"}]
    end
  end

  test "stop/1 tolerates an already-stopped listener", %{server: server} do
    assert :ok = MCPServer.stop(server)
    assert :ok = MCPServer.stop(server)
    refute Process.alive?(server.pid)
  end

  defp tracker_binding(recorder) do
    %{
      adapter: FakeAdapter,
      tracker_settings: %{recorder: recorder},
      tool_specs: @tool_specs,
      secret_environment_names: []
    }
  end

  defp mcp_url(server), do: mcp_url(server, server.token)
  defp mcp_url(server, token), do: "http://127.0.0.1:#{server.port}/mcp/#{token}"

  defp rpc(server, body), do: rpc(server, server.token, body)
  defp rpc(server, token, body), do: Req.post!(mcp_url(server, token), json: body)
end
