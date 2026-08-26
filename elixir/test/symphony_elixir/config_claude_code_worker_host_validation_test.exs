defmodule SymphonyElixir.ConfigClaudeCodeWorkerHostValidationTest do
  use SymphonyElixir.TestSupport

  test "omitted agent_execution.kind resolves to the Codex default" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert :ok = Config.validate!()
    assert Config.settings!().agent_execution.kind == "codex"
  end

  test "omitted claude_code.command resolves to the scoped local-execution default, not --bare" do
    write_workflow_file!(Workflow.workflow_file_path())

    assert :ok = Config.validate!()
    command = Config.settings!().claude_code.command

    assert command ==
             "claude --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config"

    refute command =~ "--bare"
  end

  test "worker.ssh_hosts alone with agent_execution.kind: codex (default) is unaffected" do
    write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["build-host"])

    assert :ok = Config.validate!()
    assert Config.settings!().agent_execution.kind == "codex"
    assert Config.settings!().worker.ssh_hosts == ["build-host"]
  end

  test "agent_execution.kind: claude_code with non-empty worker.ssh_hosts fails startup validation with a clear message" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      worker_ssh_hosts: ["build-host"]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.ssh_hosts"
    assert message =~ "agent_execution.kind: codex"
  end

  test "valid Claude Code configuration without SSH hosts is accepted" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      claude_code_command: "claude --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config",
      claude_code_turn_timeout_ms: 1_800_000,
      claude_code_read_timeout_ms: 2_500
    )

    assert :ok = Config.validate!()

    settings = Config.settings!()
    assert settings.agent_execution.kind == "claude_code"
    assert settings.worker.ssh_hosts == []

    assert settings.claude_code.command ==
             "claude --setting-sources project,local --permission-mode bypassPermissions --strict-mcp-config"

    assert settings.claude_code.turn_timeout_ms == 1_800_000
    assert settings.claude_code.read_timeout_ms == 2_500
  end

  test "claude_code.command blank/whitespace-only is rejected, mirroring codex.command" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      claude_code_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "claude_code.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      claude_code_command: "   "
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "claude_code.command"
    assert message =~ "can't be blank"
  end

  test "claude_code timeout fields must be positive integers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      claude_code_turn_timeout_ms: 0
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "claude_code.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_execution_kind: "claude_code",
      claude_code_read_timeout_ms: 0
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "claude_code.read_timeout_ms"
  end

  test "an unsupported agent_execution.kind fails startup validation instead of silently resolving (T027)" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_execution_kind: "not-a-real-kind")

    assert {:error, reason} = Config.validate!()
    assert reason == {:unsupported_agent_execution_kind, "not-a-real-kind"}
  end
end
