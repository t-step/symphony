defmodule SymphonyElixir.Bindle.Projection do
  @moduledoc """
  Read-only reader for Bindle's externally-published `symphony-projection.sqlite3` artifact — the
  `task_projection` table, versioned by `PRAGMA user_version = 1`.

  Every function opens its own short-lived read-only connection (`Exqlite.Sqlite3.open/2` with
  `mode: :readonly`) and closes it before returning — no connection is held between polls
  (data-model.md §2, contracts §5). This module never creates, migrates, or repairs the artifact, and
  never opens any file other than the one configured path — in particular, never a Bindle canonical
  ledger file (FR-002/FR-004).
  """

  alias SymphonyElixir.Tracker.Issue

  @schema_version 1
  @columns ["id", "identifier", "title", "description", "status", "dispatchable", "created_at"]

  @spec open_and_validate(String.t()) :: :ok | {:error, term()}
  def open_and_validate(path) when is_binary(path) do
    with_connection(path, fn _conn -> :ok end)
  end

  @spec fetch_by_states(String.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_by_states(_path, []), do: {:ok, []}

  def fetch_by_states(path, state_names) when is_binary(path) and is_list(state_names) do
    query_rows(path, "status", state_names)
  end

  @spec fetch_by_ids(String.t(), [String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_by_ids(_path, []), do: {:ok, []}

  def fetch_by_ids(path, issue_ids) when is_binary(path) and is_list(issue_ids) do
    query_rows(path, "id", issue_ids)
  end

  @doc """
  Returns every task id currently present in the projection, regardless of `dispatchable` — used only
  by startup-time stale-claim reconciliation, never by the ordinary poll path. Performs no lifecycle
  interpretation of any kind.
  """
  @spec list_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_ids(path) when is_binary(path) do
    with_connection(path, fn conn ->
      with {:ok, rows} <- select_rows(conn, "SELECT id FROM task_projection", []) do
        {:ok, Enum.map(rows, fn [id] -> id end)}
      end
    end)
  end

  defp query_rows(path, column, values) do
    with_connection(path, fn conn ->
      placeholders = Enum.map_join(values, ",", fn _ -> "?" end)

      sql =
        "SELECT #{Enum.join(@columns, ",")} FROM task_projection WHERE #{column} IN (#{placeholders})"

      with {:ok, rows} <- select_rows(conn, sql, values) do
        rows_to_issues(rows)
      end
    end)
  end

  defp rows_to_issues(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case row_to_issue(row) do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_to_issue([id, identifier, title, description, status, dispatchable, created_at]) do
    with {:ok, id} <- require_present(id, :id),
         {:ok, identifier} <- require_present(identifier, :identifier),
         {:ok, title} <- require_present(title, :title),
         {:ok, status} <- require_present(status, :status),
         {:ok, created_at} <- parse_created_at(created_at) do
      {:ok,
       %Issue{
         id: id,
         identifier: identifier,
         title: title,
         description: description,
         state: status,
         dispatchable: dispatchable in [1, true],
         created_at: created_at
       }}
    end
  end

  defp require_present(value, _field) when is_binary(value) do
    if String.trim(value) != "", do: {:ok, value}, else: {:error, :malformed_projection_row}
  end

  defp require_present(_value, _field), do: {:error, :malformed_projection_row}

  # `created_at` is `TEXT NOT NULL` in the projection schema, and exqlite always returns a TEXT
  # column's value as an Elixir binary — a non-binary value is not a case a valid row can produce, so
  # this has a single clause rather than a defensive (and untestable-through-the-public-API) fallback.
  defp parse_created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :malformed_projection_row}
    end
  end

  defp with_connection(path, fun) do
    case open(path) do
      {:ok, conn} ->
        result =
          with :ok <- check_schema_version(conn) do
            fun.(conn)
          end

        Exqlite.Sqlite3.close(conn)
        result

      {:error, reason} ->
        {:error, {:bindle_projection_open_failed, reason}}
    end
  end

  # `Exqlite.Sqlite3.open/2` returns `{:error, reason}` for every failure mode it can encounter
  # (missing file, path is a directory, etc.) — verified directly, it does not raise — so this has
  # no rescue wrapper unlike `select_rows/3` below, whose `bind/2` call genuinely can raise for a
  # caller-supplied value of an unsupported type.
  defp open(path) do
    Exqlite.Sqlite3.open(path, mode: :readonly)
  end

  # `PRAGMA user_version` always returns exactly one row with one integer column — there is no
  # third shape for a successful query to defend against, so this only branches on the version
  # matching or not, plus the query itself failing (e.g. the file is not a valid SQLite database).
  defp check_schema_version(conn) do
    case select_rows(conn, "PRAGMA user_version", []) do
      {:ok, [[@schema_version]]} -> :ok
      {:ok, [[other_version]]} -> {:error, {:unsupported_projection_version, other_version}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_rows(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- bind_params(stmt, params),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, rows}
    else
      {:error, reason} -> {:error, {:bindle_projection_query_failed, reason}}
    end
  rescue
    e -> {:error, {:bindle_projection_query_failed, Exception.message(e)}}
  end

  defp bind_params(_stmt, []), do: :ok
  defp bind_params(stmt, params), do: Exqlite.Sqlite3.bind(stmt, params)
end
