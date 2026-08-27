defmodule SymphonyElixir.Local.Store do
  @moduledoc """
  Owns the local work-tracking source's SQLite database and establishment marker.

  Every read (used by `Local.Adapter`'s `fetch_issues_by_states/1`/`fetch_issues_by_ids/1`) and the
  one ongoing lifecycle write (`local_tracker_set_state`) go through this named `GenServer`, whose
  mailbox serializes access so two concurrently-running work-item attempts can never race a
  read-modify-write cycle against each other.

  This module's read path NEVER creates the database file or its marker, under any circumstance —
  establishment (creating the database, its `work_items` table/`work_item_projection` view, and the
  marker) is performed exclusively by `SymphonyElixir.Local.Init`. Every call opens a fresh,
  short-lived connection and re-queries SQLite rather than caching parsed content or holding a
  connection open across calls, so an out-of-band change (a deleted file, a hand-edited row, a
  freshly-completed `local-tracker init`) is always observed on the next call, and so a
  deleted/corrupted file is detected promptly rather than continuing to serve a stale open file
  handle.

  `work_items` is deliberately the only table this module owns. It is a small, intentionally flat
  Symphony-facing record — id/identifier/title/description/priority/state/branch_name/url/
  assignee_id/labels/blocked_by/dispatchable/created_at/updated_at — not a richer work-item model
  (milestones, dependencies-as-a-graph, lifecycle history). `work_item_projection` is a plain SQL
  view over `work_items` selecting exactly those columns.

  This module is Symphony's own standalone, independent local work-tracking implementation
  (`001-local-tracker-multi-agent`) — it is not, and must not be treated as, the future canonical
  persistence layer for a Bindle integration. A future Bindle-backed tracker (`002-bindle-integration`)
  would be an entirely separate `SymphonyElixir.Tracker` adapter, reading a projection Bindle itself
  owns and publishes, not a growth path of this module, its schema, or `work_item_projection`. The two
  systems are independent and share no storage, schema, or lifecycle, even though both currently happen
  to use SQLite.

  The establishment marker (`<path>.established`) still exists here — unlike the rest of the
  JSON-file-backed predecessor this module replaced, it is NOT a data file: it carries no work-item
  content, only a durable "this path was established by `Local.Init`" fact, independent of the
  SQLite file's own existence. It is required specifically because SQLite's self-describing schema
  can only answer "is this database currently valid" — it cannot answer "was this database ever
  established" once the database file itself has been deleted, which is exactly the FR-013 case
  (previously-established durable state going missing) Symphony must distinguish from "never
  initialized" and refuse to silently treat as a fresh, empty store. Unlike the old JSON store,
  there is no "ambiguous state, recoverable by completing the marker" case: `Local.Init` is the only
  plausible creator of a valid `work_items` database (nobody hand-authors a correctly-shaped SQLite
  file the way one could hand-edit JSON), so a database present without its marker is treated as a
  corrupt/inconsistent state rather than a legitimate pre-existing store awaiting establishment.
  """

  use GenServer

  alias Exqlite.Basic

  defstruct [:data_path, :marker_path]

  @type read_error ::
          :local_tracker_not_initialized
          | {:local_tracker_corrupt, term()}

  @create_table_sql """
  CREATE TABLE IF NOT EXISTS work_items (
    id TEXT PRIMARY KEY,
    identifier TEXT,
    title TEXT,
    description TEXT,
    priority INTEGER,
    state TEXT,
    branch_name TEXT,
    url TEXT,
    assignee_id TEXT,
    labels TEXT NOT NULL DEFAULT '[]',
    blocked_by TEXT NOT NULL DEFAULT '[]',
    dispatchable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT,
    updated_at TEXT
  )
  """

  @create_view_sql """
  CREATE VIEW IF NOT EXISTS work_item_projection AS
  SELECT
    id, identifier, title, description, priority, state, branch_name, url,
    assignee_id, labels, blocked_by, dispatchable, created_at, updated_at
  FROM work_items
  """

  @schema_check_sql "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'work_items'"

  @select_all_sql """
  SELECT id, identifier, title, description, priority, state, branch_name, url,
         assignee_id, labels, blocked_by, dispatchable, created_at, updated_at
  FROM work_item_projection
  """

  @select_one_sql "#{@select_all_sql} WHERE id = ?"

  @update_state_sql "UPDATE work_items SET state = ?, updated_at = ? WHERE id = ?"

  ## Public API (GenServer-backed; serializes reads and the one lifecycle write)

  @doc """
  Starts the store against the given database `path`. Accepts the same options as
  `GenServer.start_link/3` (e.g. `:name`) — the caller decides whether/how to register a name;
  this module does not force one, so tests can run multiple independent stores concurrently.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {path, gen_opts} = Keyword.pop!(opts, :path)
    GenServer.start_link(__MODULE__, %{data_path: Path.expand(path)}, gen_opts)
  end

  @doc """
  Re-queries the database and evaluates its establishment/schema state. Never creates the file or
  the marker.
  """
  @spec read(GenServer.server()) :: {:ok, %{issues: map()}} | {:error, read_error()}
  def read(server \\ __MODULE__) do
    GenServer.call(server, :read)
  end

  @doc """
  Rewrites `issues[id].state` (and `updated_at`) via a single `UPDATE`. A no-op (still a success,
  no write performed) when `new_state` already matches the current value. Fails with the same
  `read_error/0` the store would report for this data if it is not established, and with
  `:issue_not_found` if `id` is not present in `work_items`.
  """
  @spec set_issue_state(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, read_error() | :issue_not_found | term()}
  def set_issue_state(server \\ __MODULE__, id, new_state) do
    GenServer.call(server, {:set_issue_state, id, new_state})
  end

  ## Public API (pure helpers; no GenServer process required)
  ##
  ## Shared with `SymphonyElixir.Local.Init`, which performs establishment (creating the database
  ## file, its schema, and the marker) as a separate, short-lived operation outside any running
  ## `Local.Store` process, but must apply this exact same presence/schema check.

  @doc false
  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(data_path), do: data_path <> ".established"

  @doc false
  @spec marker_present?(Path.t()) :: boolean()
  def marker_present?(marker_path), do: File.exists?(marker_path)

  @doc """
  Evaluates the store's establishment/schema state against `data_path` directly, without requiring
  a running `Local.Store` process. Used by `Local.Adapter.validate_config/1`, which must be
  callable before (or without) the singleton `Local.Store` GenServer being started. Never creates
  the file or the marker. This is the same decision logic the GenServer's `read/1` callback
  applies; both share this one implementation.
  """
  @spec evaluate(Path.t()) :: {:ok, %{issues: map()}} | {:error, read_error()}
  def evaluate(data_path), do: do_read(data_path)

  @doc false
  @spec create_schema(Exqlite.Connection.t()) :: :ok | {:error, term()}
  def create_schema(conn) do
    with {:ok, _rows, _cols} <- Basic.exec(conn, @create_table_sql) |> Basic.rows(),
         {:ok, _rows, _cols} <- Basic.exec(conn, @create_view_sql) |> Basic.rows() do
      :ok
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_path: data_path}) do
    {:ok, %__MODULE__{data_path: data_path, marker_path: marker_path(data_path)}}
  end

  @impl true
  def handle_call(:read, _from, %__MODULE__{data_path: data_path} = state) do
    {:reply, do_read(data_path), state}
  end

  def handle_call({:set_issue_state, id, new_state}, _from, %__MODULE__{data_path: data_path} = state) do
    {:reply, do_set_issue_state(data_path, id, new_state), state}
  end

  ## Read path — never creates the database file or the marker.

  defp do_read(data_path) do
    with_established_connection(data_path, fn conn ->
      case select_all(conn) do
        {:ok, issues} -> {:ok, %{issues: issues}}
        {:error, reason} -> {:error, {:local_tracker_corrupt, reason}}
      end
    end)
  end

  ## The one ongoing lifecycle write. Only ever runs against an already-established database
  ## (never creates or completes establishment itself).

  defp do_set_issue_state(data_path, id, new_state) do
    with_established_connection(data_path, fn conn ->
      case fetch_one(conn, id) do
        {:ok, nil} ->
          {:error, :issue_not_found}

        {:ok, %{"state" => ^new_state} = record} ->
          {:ok, record}

        {:ok, record} ->
          apply_state_update(conn, id, new_state, record)

        {:error, reason} ->
          {:error, {:local_tracker_corrupt, reason}}
      end
    end)
  end

  defp apply_state_update(conn, id, new_state, record) do
    now = now_iso8601()

    case Basic.exec(conn, @update_state_sql, [new_state, now, id]) |> Basic.rows() do
      {:ok, _rows, _cols} -> {:ok, record |> Map.put("state", new_state) |> Map.put("updated_at", now)}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Establishment decision table (FR-013): distinguishes "not yet established" from "established,
  ## now missing/corrupt" using the marker's presence, since the marker survives the database file's
  ## own deletion (the exact case FR-013 requires Symphony to detect rather than silently treat as a
  ## fresh, empty store) — mirrors research.md R2/R2a's table, minus the JSON-only "ambiguous state,
  ## recoverable by completing the marker" case (see moduledoc).

  defp with_established_connection(data_path, fun) do
    marker_path = marker_path(data_path)
    data_present? = File.exists?(data_path)

    case {marker_present?(marker_path), data_present?} do
      {false, false} -> {:error, :local_tracker_not_initialized}
      {false, true} -> {:error, {:local_tracker_corrupt, :marker_missing}}
      {true, false} -> {:error, {:local_tracker_corrupt, :missing_after_established}}
      {true, true} -> open_established(data_path, fun)
    end
  end

  defp open_established(data_path, fun) do
    case Basic.open(data_path) do
      {:ok, conn} ->
        try do
          case schema_check(conn) do
            :ok -> fun.(conn)
            {:error, reason} -> {:error, {:local_tracker_corrupt, reason}}
          end
        after
          Basic.close(conn)
        end

      {:error, %{message: message}} ->
        {:error, {:local_tracker_corrupt, message}}
    end
  end

  defp schema_check(conn) do
    with {:ok, rows, _columns} <- Basic.exec(conn, @schema_check_sql) |> Basic.rows() do
      case rows do
        [_row] -> :ok
        [] -> {:error, :missing_schema}
      end
    end
  end

  ## Row decoding — SQLite has no native list type, so `labels`/`blocked_by` are stored as
  ## JSON-encoded TEXT and decoded back into lists here; `dispatchable` is stored as 0/1 and decoded
  ## back into a boolean. A row whose JSON columns fail to decode is surfaced as a structured
  ## corruption error rather than crashing or being silently dropped — the same defect class the
  ## JSON-file predecessor guarded against for a non-map issue record.

  defp select_all(conn) do
    with {:ok, rows, columns} <- Basic.exec(conn, @select_all_sql) |> Basic.rows() do
      rows_to_issue_map(rows, columns)
    end
  end

  defp fetch_one(conn, id) do
    with {:ok, rows, columns} <- Basic.exec(conn, @select_one_sql, [id]) |> Basic.rows() do
      case rows do
        [] -> {:ok, nil}
        [row] -> row_to_record(columns, row) |> to_single_result()
      end
    end
  end

  defp to_single_result({:ok, _id, record}), do: {:ok, record}
  defp to_single_result({:error, _reason} = error), do: error

  defp rows_to_issue_map(rows, columns) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, acc} ->
      case row_to_record(columns, row) do
        {:ok, id, record} -> {:cont, {:ok, Map.put(acc, id, record)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp row_to_record(columns, row) do
    raw = columns |> Enum.map(&to_string/1) |> Enum.zip(row) |> Map.new()
    id = Map.fetch!(raw, "id")

    with {:ok, labels} <- decode_json_list(raw["labels"], id, "labels"),
         {:ok, blocked_by} <- decode_json_list(raw["blocked_by"], id, "blocked_by") do
      record =
        raw
        |> Map.put("labels", labels)
        |> Map.put("blocked_by", blocked_by)
        |> Map.put("dispatchable", raw["dispatchable"] in [1, true])

      {:ok, id, record}
    end
  end

  defp decode_json_list(text, id, column) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, {:invalid_column_shape, id, column, other}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_column_json, id, column, Exception.message(error)}}
    end
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
