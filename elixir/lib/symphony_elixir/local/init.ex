defmodule SymphonyElixir.Local.Init do
  @moduledoc """
  The *only* code path in this feature that creates the local work-tracking source's SQLite
  database (its `work_items` table, `work_item_projection` view) or its establishment marker
  (research.md R2/R2a). Symphony's running orchestrator process — `SymphonyElixir.Local.Store`'s
  read path, startup validation, polling, dispatch — never creates either, under any circumstance.

  Invoked by the packaged CLI's `symphony local-tracker init` subcommand; this module itself takes
  an already-resolved database path and has no `WORKFLOW.md`-loading or CLI-argument concerns of
  its own.
  """

  alias Exqlite.Basic
  alias SymphonyElixir.Local.Store

  @type outcome :: :initialized | :reset

  @doc """
  Establishes the local tracker database at `path` (the marker is its `Store.marker_path/1`
  sibling).

  Without `reset: true`:

  - both absent → creates the database (`work_items` table, `work_item_projection` view) then the
    marker, in that order (database first, so a crash between the two writes leaves "database
    present, marker absent" — a corrupt/inconsistent state, not a torn database).
  - the marker is present (established, regardless of the database's own health) → refuses with
    `{:error, :already_established}`; only `reset: true` may overwrite an established store.
  - the marker is absent but the database file already exists → refuses with
    `{:error, {:ambiguous_local_tracker_state, :marker_missing}}`. Unlike the JSON-file predecessor,
    there is no "complete establishment" recovery path here: nobody plausibly hand-authors a
    correctly-shaped SQLite database the way one could hand-edit JSON, so a database present without
    the marker is treated as inconsistent state requiring `--reset` rather than a legitimate
    pre-existing store.

  With `reset: true`: deletes the database (and any leftover rollback-journal sidecar) and the
  marker if present, then creates a fresh pair unconditionally.
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
    cond do
      Store.marker_present?(marker_path) -> {:error, :already_established}
      File.exists?(data_path) -> {:error, {:ambiguous_local_tracker_state, :marker_missing}}
      true -> finish_init(create_fresh(data_path, marker_path))
    end
  end

  defp finish_init(:ok), do: {:ok, :initialized}
  defp finish_init({:error, _reason} = error), do: error

  defp do_reset(data_path, marker_path) do
    with :ok <- remove_if_exists(data_path),
         :ok <- remove_if_exists(data_path <> "-journal"),
         :ok <- remove_if_exists(marker_path),
         :ok <- create_fresh(data_path, marker_path) do
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

  defp create_fresh(data_path, marker_path) do
    with :ok <- File.mkdir_p(Path.dirname(data_path)),
         :ok <- create_database(data_path) do
      write_marker(marker_path)
    else
      {:error, %{message: message}} -> discard_partial(data_path, message)
      {:error, reason} -> discard_partial(data_path, reason)
    end
  end

  defp create_database(data_path) do
    case Basic.open(data_path) do
      {:ok, conn} ->
        result = Store.create_schema(conn)
        Basic.close(conn)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard_partial(data_path, reason) do
    File.rm(data_path)
    {:error, reason}
  end

  defp write_marker(marker_path) do
    File.write(marker_path, Jason.encode!(%{"established_at" => now_iso8601()}))
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
