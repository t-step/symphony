defmodule SymphonyElixir.Local.Init do
  @moduledoc """
  The *only* code path in this feature that writes the local work-tracking source's data file's
  initial content or its establishment marker (research.md R2/R2a). Symphony's running orchestrator
  process — `SymphonyElixir.Local.Store`'s read path, startup validation, polling, dispatch — never
  creates or completes either file, under any circumstance.

  Invoked by the packaged CLI's `symphony local-tracker init` subcommand (a later task); this module
  itself takes an already-resolved data file path and has no `WORKFLOW.md`-loading or CLI-argument
  concerns of its own.
  """

  alias SymphonyElixir.Local.Store

  @type outcome :: :initialized | :marker_completed | :reset

  @doc """
  Establishes the local tracker store at `path` (the data file's resolved location; the marker is
  its `Store.marker_path/1` sibling).

  Without `reset: true`:

  - both files absent → creates the data file (`{"format_version": 1, "issues": {}}`) then the
    marker, in that order (data file first, so a crash between the two writes leaves "data present,
    marker absent" — R2's ambiguous row, not a torn file).
  - marker present (established, regardless of the data file's own health) → refuses with
    `{:error, :already_established}`; only `reset: true` may overwrite an established store.
  - marker absent, data file present and valid → completes establishment by writing only the
    marker; the data file is never touched.
  - marker absent, data file present but unparseable → refuses with
    `{:error, {:unparseable_data_file, reason}}`; this is not a case `init` can safely resolve.

  With `reset: true`: deletes both files if present, then performs the same two-file creation as
  the fresh-deployment case above, unconditionally.
  """
  @spec run(Path.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(path, opts \\ []) do
    data_path = Path.expand(path)
    marker_path = Store.marker_path(data_path)

    if Keyword.get(opts, :reset, false) do
      do_reset(data_path, marker_path)
    else
      do_init(data_path, marker_path)
    end
  end

  defp do_init(data_path, marker_path) do
    case Store.marker_state(marker_path) do
      :present ->
        {:error, :already_established}

      {:unreadable, reason} ->
        {:error, {:marker_unreadable, reason}}

      :absent ->
        complete_or_create(data_path, marker_path)
    end
  end

  defp complete_or_create(data_path, marker_path) do
    case Store.read_data_file(data_path) do
      :absent ->
        case write_fresh(data_path, marker_path) do
          :ok -> {:ok, :initialized}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _parsed} ->
        case write_marker(marker_path) do
          :ok -> {:ok, :marker_completed}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:unparseable_data_file, reason}}
    end
  end

  defp do_reset(data_path, marker_path) do
    with :ok <- remove_if_exists(data_path),
         :ok <- remove_if_exists(marker_path),
         :ok <- write_fresh(data_path, marker_path) do
      {:ok, :reset}
    end
  end

  defp remove_if_exists(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_fresh(data_path, marker_path) do
    case Store.atomic_write(data_path, Jason.encode!(%{"format_version" => 1, "issues" => %{}})) do
      :ok -> write_marker(marker_path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_marker(marker_path) do
    Store.atomic_write(marker_path, Jason.encode!(%{"established_at" => now_iso8601()}))
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
