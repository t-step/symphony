defmodule SymphonyElixir.Bindle.CliTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Bindle.Cli

  setup do
    repo_path = Path.join(System.tmp_dir!(), "bindle-cli-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)
    on_exit(fn -> File.rm_rf(repo_path) end)

    fake_bin = write_fake_bindle_bin!(repo_path)

    {:ok, repo_path: repo_path, fake_bin: fake_bin}
  end

  test "claim/4 invokes `bindle work claim <id> --owner <owner>` with cd: repo_path, no worktree/branch",
       %{repo_path: repo_path, fake_bin: fake_bin} do
    assert {:ok, output} = Cli.claim(repo_path, fake_bin, "task-1", "owner-a")
    assert output =~ "args=work claim task-1 --owner owner-a"
    assert output =~ Path.basename(repo_path)
    refute output =~ "--worktree"
    refute output =~ "--branch"
  end

  test "release/4 invokes `bindle work release <id> --owner <owner>` with cd: repo_path", %{
    repo_path: repo_path,
    fake_bin: fake_bin
  } do
    assert {:ok, output} = Cli.release(repo_path, fake_bin, "task-1", "owner-a")
    assert output =~ "args=work release task-1 --owner owner-a"
    assert output =~ Path.basename(repo_path)
  end

  test "a non-zero exit is mapped to a distinguishable {:error, {:bindle_cli_failed, exit_code, output}}",
       %{repo_path: repo_path} do
    failing_bin = write_fake_bindle_bin!(repo_path, exit_code: 1, stderr: "bindle work claim: already_claimed")

    assert {:error, {:bindle_cli_failed, 1, output}} = Cli.claim(repo_path, failing_bin, "task-1", "owner-a")
    assert output =~ "already_claimed"
  end

  test "a missing binary is mapped to a distinguishable {:error, {:bindle_cli_unavailable, _}}", %{
    repo_path: repo_path
  } do
    assert {:error, {:bindle_cli_unavailable, _reason}} =
             Cli.claim(repo_path, "definitely-not-a-real-bindle-binary", "task-1", "owner-a")
  end

  test "done/3 invokes `bindle work done <id>` with cd: repo_path, no --owner argument", %{
    repo_path: repo_path,
    fake_bin: fake_bin
  } do
    assert {:ok, output} = Cli.done(repo_path, fake_bin, "task-1")
    assert output =~ "args=work done task-1"
    refute output =~ "--owner"
    assert output =~ Path.basename(repo_path)
  end

  test "publish/2 invokes `bindle work publish` with cd: repo_path, no --owner argument", %{
    repo_path: repo_path,
    fake_bin: fake_bin
  } do
    assert {:ok, output} = Cli.publish(repo_path, fake_bin)
    assert output =~ "args=work publish"
    refute output =~ "--owner"
    assert output =~ Path.basename(repo_path)
  end

  test "done/3 and publish/2 use the same exit-code/stderr convention as claim/release", %{repo_path: repo_path} do
    failing_bin = write_fake_bindle_bin!(repo_path, exit_code: 1, stderr: "bindle work done: not_open")

    assert {:error, {:bindle_cli_failed, 1, output}} = Cli.done(repo_path, failing_bin, "task-1")
    assert output =~ "not_open"

    assert {:error, {:bindle_cli_unavailable, _reason}} =
             Cli.publish(repo_path, "definitely-not-a-real-bindle-binary")
  end

  defp write_fake_bindle_bin!(repo_path, opts \\ []) do
    exit_code = Keyword.get(opts, :exit_code, 0)
    stderr = Keyword.get(opts, :stderr)

    path = Path.join(repo_path, "fake-bindle-#{System.unique_integer([:positive])}.sh")

    script = """
    #!/bin/sh
    echo "args=$*"
    echo "cwd=$(pwd)"
    #{if stderr, do: "echo #{inspect(stderr)} 1>&2"}
    exit #{exit_code}
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
