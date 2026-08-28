defmodule SymphonyElixir.Bindle.Cli do
  @moduledoc """
  Thin `System.cmd/3` wrapper over Bindle's own supported CLI write surface.

  `claim/4` and `release/4` are called only from the orchestrator-owned claim/release seam
  (`SymphonyElixir.Bindle.Adapter.acquire_issue/2`/`release_issue/2`). `done/3` and `publish/2` are
  called only from `SymphonyElixir.Bindle.AgentTool` — never from the claim/release seam (FR-018,
  FR-025–FR-028). No function here issues a raw database mutation.
  """

  @spec claim(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def claim(repo_path, bindle_bin, id, owner) do
    run(repo_path, bindle_bin, ["work", "claim", id, "--owner", owner])
  end

  @spec release(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def release(repo_path, bindle_bin, id, owner) do
    run(repo_path, bindle_bin, ["work", "release", id, "--owner", owner])
  end

  @doc "Invokes `bindle work done <id>` — no `--owner` argument; Bindle's `done` write surface has no ownership/claim requirement."
  @spec done(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def done(repo_path, bindle_bin, id) do
    run(repo_path, bindle_bin, ["work", "done", id])
  end

  @doc "Invokes `bindle work publish` — no `--owner` argument."
  @spec publish(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def publish(repo_path, bindle_bin) do
    run(repo_path, bindle_bin, ["work", "publish"])
  end

  defp run(repo_path, bindle_bin, args) do
    case System.cmd(bindle_bin, args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {:bindle_cli_failed, exit_code, output}}
    end
  rescue
    e -> {:error, {:bindle_cli_unavailable, Exception.message(e)}}
  end
end
