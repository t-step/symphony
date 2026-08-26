defmodule SymphonyElixir.AgentRunnerDispatchTest do
  @moduledoc """
  T028: proves `AgentRunner.run/3` dispatches to the concrete `CodingAgent`
  implementation selected by the structural `agent_execution.kind` snapshot
  (T027), through the ordinary `AgentRunner.run/3` execution boundary rather
  than a helper that merely maps strings to modules — and proves inactive-
  provider configuration/credentials are neither consulted nor leaked into
  the active provider's subprocess (FR-009).
  """

  use SymphonyElixir.TestSupport

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-agent-runner-dispatch-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace_root: workspace_root, issue: build_issue()}
  end

  test "default/no agent_execution.kind config dispatches to Codex", %{
    test_root: test_root,
    workspace_root: workspace_root,
    issue: issue
  } do
    codex_binary = write_fake_codex!(test_root, "codex-invoked.marker")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server"
    )

    assert :ok = AgentRunner.run(issue)
    assert File.exists?(Path.join(test_root, "codex-invoked.marker"))
    refute File.exists?(Path.join(test_root, "claude-invoked.marker"))
  end

  test "explicit agent_execution.kind: codex dispatches to Codex and does not consult claude_code config", %{
    test_root: test_root,
    workspace_root: workspace_root,
    issue: issue
  } do
    codex_binary = write_fake_codex!(test_root, "codex-invoked.marker")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "codex",
      codex_command: "#{codex_binary} app-server",
      # A garbage, nonexistent claude_code.command: if the Codex dispatch path ever
      # consulted the inactive integration's config, resolving/launching it would fail
      # loudly and this run would not succeed.
      claude_code_command: "/nonexistent/symphony-claude-binary-#{System.unique_integer([:positive])}"
    )

    restart_workflow_store!()

    assert :ok = AgentRunner.run(issue)
    assert File.exists?(Path.join(test_root, "codex-invoked.marker"))
    refute File.exists?(Path.join(test_root, "claude-invoked.marker"))
  end

  test "explicit agent_execution.kind: claude_code dispatches to ClaudeCode.AppServer and does not consult codex config",
       %{test_root: test_root, workspace_root: workspace_root, issue: issue} do
    claude_binary = write_fake_claude!(test_root, "claude-invoked.marker")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "claude_code",
      claude_code_command: claude_binary,
      # A garbage, nonexistent codex.command: proves the claude_code dispatch path never
      # falls back to or consults the inactive Codex integration's config.
      codex_command: "/nonexistent/symphony-codex-binary-#{System.unique_integer([:positive])}"
    )

    restart_workflow_store!()

    # `ClaudeCode.AppServer.start_session/2` returns `{:error, :issue_required}` unless
    # `opts[:issue]` is present, which would surface here as a raised RuntimeError — so this
    # `:ok` assertion also proves `issue: issue` reached the selected implementation.
    assert :ok = AgentRunner.run(issue)
    assert File.exists?(Path.join(test_root, "claude-invoked.marker"))
    refute File.exists?(Path.join(test_root, "codex-invoked.marker"))
  end

  test "a claude_code-backed run excludes OPENAI_API_KEY and other unrelated env from the subprocess", %{
    test_root: test_root,
    workspace_root: workspace_root,
    issue: issue
  } do
    claude_binary = write_fake_claude_env_dump!(test_root)

    System.put_env("OPENAI_API_KEY", "sk-openai-should-not-leak")
    System.put_env("SYMPHONY_TEST_UNRELATED_VAR", "should-not-leak-either")

    on_exit(fn ->
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("SYMPHONY_TEST_UNRELATED_VAR")
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "claude_code",
      claude_code_command: claude_binary
    )

    restart_workflow_store!()

    assert :ok = AgentRunner.run(issue)

    env_dump = File.read!(Path.join(test_root, "claude-env.txt"))
    refute env_dump =~ "OPENAI_API_KEY"
    refute env_dump =~ "SYMPHONY_TEST_UNRELATED_VAR"
  end

  test "a codex-backed run excludes ANTHROPIC_API_KEY and other unrelated env from the subprocess", %{
    test_root: test_root,
    workspace_root: workspace_root,
    issue: issue
  } do
    codex_binary = write_fake_codex_env_dump!(test_root)

    System.put_env("ANTHROPIC_API_KEY", "sk-ant-should-not-leak")
    System.put_env("SYMPHONY_TEST_UNRELATED_VAR", "should-still-be-present")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("SYMPHONY_TEST_UNRELATED_VAR")
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "codex",
      codex_command: "#{codex_binary} app-server"
    )

    restart_workflow_store!()

    assert :ok = AgentRunner.run(issue)

    env_dump = File.read!(Path.join(test_root, "codex-env.txt"))
    refute env_dump =~ "ANTHROPIC_API_KEY"
    refute env_dump =~ "sk-ant-should-not-leak"
    assert env_dump =~ "SYMPHONY_TEST_UNRELATED_VAR"
  end

  test "dispatch selection comes from the pinned structural snapshot, not a live-reloaded edit", %{
    test_root: test_root,
    workspace_root: workspace_root,
    issue: issue
  } do
    codex_binary = write_fake_codex!(test_root, "codex-invoked.marker")
    claude_binary = write_fake_claude!(test_root, "unexpected-claude-invocation.marker")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "codex",
      codex_command: "#{codex_binary} app-server",
      claude_code_command: claude_binary
    )

    restart_workflow_store!()

    # Live-edit agent_execution.kind to claude_code WITHOUT restarting the WorkflowStore
    # (IV-005/research.md R9) — the structural pin must keep resolving to Codex.
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_execution_kind: "claude_code",
      codex_command: "#{codex_binary} app-server",
      claude_code_command: claude_binary
    )

    assert Config.settings!().agent_execution.kind == "claude_code"
    assert Config.structural_settings!().agent_execution_kind == "codex"

    assert :ok = AgentRunner.run(issue)
    assert File.exists?(Path.join(test_root, "codex-invoked.marker"))

    refute File.exists?(Path.join(test_root, "unexpected-claude-invocation.marker")),
           "a live (non-restarted) agent_execution.kind edit must not redirect dispatch mid-run"
  end

  defp build_issue do
    %Issue{
      identifier: "MT-DISPATCH",
      title: "Prove coding-agent dispatch resolution",
      description: "Exercises AgentRunner.run/3's ordinary execution boundary",
      state: "In Progress",
      url: "https://example.org/issues/MT-DISPATCH",
      labels: []
    }
  end

  defp write_fake_codex!(test_root, marker_name) do
    codex_binary = Path.join(test_root, "fake-codex")
    marker_path = Path.join(test_root, marker_name)

    File.write!(codex_binary, """
    #!/bin/sh
    touch #{shell_quote(marker_path)}
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dispatch"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dispatch"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    codex_binary
  end

  defp write_fake_codex_env_dump!(test_root) do
    codex_binary = Path.join(test_root, "fake-codex-env-dump")
    env_dump_path = Path.join(test_root, "codex-env.txt")

    File.write!(codex_binary, """
    #!/bin/sh
    env > #{shell_quote(env_dump_path)}
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dispatch"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dispatch"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
    codex_binary
  end

  defp write_fake_claude!(test_root, marker_name) do
    claude_binary = Path.join(test_root, "fake-claude")
    marker_path = Path.join(test_root, marker_name)

    File.write!(claude_binary, """
    #!/bin/sh
    touch #{shell_quote(marker_path)}
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)

    File.chmod!(claude_binary, 0o755)
    claude_binary
  end

  defp write_fake_claude_env_dump!(test_root) do
    claude_binary = Path.join(test_root, "fake-claude")
    env_dump_path = Path.join(test_root, "claude-env.txt")

    File.write!(claude_binary, """
    #!/bin/sh
    env > #{shell_quote(env_dump_path)}
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"observed"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """)

    File.chmod!(claude_binary, 0o755)
    claude_binary
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
