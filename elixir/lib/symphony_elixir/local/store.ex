defmodule SymphonyElixir.Local.Store do
  @moduledoc """
  Owns the local work-tracking source's on-disk data file and establishment marker.

  Every read (used by `Local.Adapter`'s `fetch_issues_by_states/1`/`fetch_issues_by_ids/1`) and the
  one ongoing lifecycle write (`local_tracker_set_state`) go through this named `GenServer`, whose
  mailbox serializes access so two concurrently-running work-item attempts can never race a
  read-modify-write cycle against each other (research.md R1a).

  This module's read path NEVER writes either file, under any circumstance — establishment
  (creating the data file's initial content or the marker) is performed exclusively by
  `SymphonyElixir.Local.Init` (research.md R2/R2a). Every call re-reads both files from disk rather
  than caching parsed content, so an out-of-band change (a deleted file, a hand-edited data file, a
  freshly-completed `local-tracker init`) is always observed on the next call.
  """

  use GenServer

  defstruct [:data_path, :marker_path]

  @type read_error ::
          :local_tracker_not_initialized
          | {:local_tracker_ambiguous_state, :marker_missing}
          | {:local_tracker_corrupt, term()}

  ## Public API (GenServer-backed; serializes reads and the one lifecycle write)

  @doc """
  Starts the store against the given data file `path`. Accepts the same options as
  `GenServer.start_link/3` (e.g. `:name`) — the caller decides whether/how to register a name;
  this module does not force one, so tests can run multiple independent stores concurrently.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {path, gen_opts} = Keyword.pop!(opts, :path)
    GenServer.start_link(__MODULE__, %{data_path: Path.expand(path)}, gen_opts)
  end

  @doc """
  Re-reads the data file and marker from disk and evaluates research.md R2's decision table.
  Never writes either file.
  """
  @spec read(GenServer.server()) :: {:ok, %{format_version: 1, issues: map()}} | {:error, read_error()}
  def read(server \\ __MODULE__) do
    GenServer.call(server, :read)
  end

  @doc """
  Rewrites `issues[id].state` (and `updated_at`) and atomically replaces the data file. A no-op
  (still a success, no write performed) when `new_state` already matches the current value. Fails
  with the same `read_error/0` the store would report for this data if it is not established, and
  with `:issue_not_found` if `id` is not present in the store.
  """
  @spec set_issue_state(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, read_error() | :issue_not_found | term()}
  def set_issue_state(server \\ __MODULE__, id, new_state) do
    GenServer.call(server, {:set_issue_state, id, new_state})
  end

  ## Public API (pure filesystem helpers; no process required)
  ##
  ## Shared with `SymphonyElixir.Local.Init`, which performs establishment (writing the data file's
  ## initial content and the marker) as a separate, short-lived operation outside any running
  ## `Local.Store` process (research.md R2a) but must apply research.md R2's exact same
  ## presence/validity checks and the exact same atomic write technique.

  @doc false
  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(data_path), do: data_path <> ".established"

  @doc false
  @spec marker_state(Path.t()) :: :absent | :present | {:unreadable, term()}
  def marker_state(path) do
    case File.read(path) do
      {:ok, _content} -> :present
      {:error, :enoent} -> :absent
      {:error, reason} -> {:unreadable, reason}
    end
  end

  @doc false
  @spec read_data_file(Path.t()) :: :absent | {:ok, %{format_version: 1, issues: map()}} | {:error, term()}
  def read_data_file(path) do
    case File.read(path) do
      {:ok, content} -> decode_store(content)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  @doc """
  Writes `content` to a sibling temp file in `path`'s directory, then renames it over `path`
  (POSIX atomic rename), so a crash mid-write can never leave a torn/partial file at `path` — the
  existing file is either the old complete version or the new complete version (research.md R1).
  """
  @spec atomic_write(Path.t(), iodata()) :: :ok | {:error, term()}
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%{data_path: data_path}) do
    {:ok, %__MODULE__{data_path: data_path, marker_path: marker_path(data_path)}}
  end

  @impl true
  def handle_call(:read, _from, %__MODULE__{} = state) do
    {:reply, do_read(state), state}
  end

  def handle_call({:set_issue_state, id, new_state}, _from, %__MODULE__{} = state) do
    {:reply, do_set_issue_state(state, id, new_state), state}
  end

  ## Read path (research.md R2's decision table) — never writes.

  defp do_read(%__MODULE__{data_path: data_path, marker_path: marker_path}) do
    case marker_state(marker_path) do
      :absent ->
        case read_data_file(data_path) do
          :absent -> {:error, :local_tracker_not_initialized}
          _present_valid_or_invalid -> {:error, {:local_tracker_ambiguous_state, :marker_missing}}
        end

      {:unreadable, reason} ->
        {:error, {:local_tracker_corrupt, {:marker_unreadable, reason}}}

      :present ->
        case read_data_file(data_path) do
          :absent -> {:error, {:local_tracker_corrupt, :missing_after_established}}
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, {:local_tracker_corrupt, reason}}
        end
    end
  end

  ## The one ongoing lifecycle write. Only ever reaches the data file, never the marker; only ever
  ## runs from an already-established read (never completes/creates establishment itself).

  defp do_set_issue_state(%__MODULE__{data_path: data_path} = state, id, new_state) do
    case do_read(state) do
      {:ok, %{issues: issues} = store} ->
        apply_issue_state(data_path, store, issues, id, new_state)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_issue_state(data_path, store, issues, id, new_state) do
    case Map.fetch(issues, id) do
      :error ->
        {:error, :issue_not_found}

      {:ok, %{"state" => ^new_state} = record} ->
        {:ok, record}

      {:ok, record} ->
        updated_record = record |> Map.put("state", new_state) |> Map.put("updated_at", now_iso8601())
        updated_store = %{store | issues: Map.put(issues, id, updated_record)}

        case atomic_write(data_path, Jason.encode!(encode_store(updated_store))) do
          :ok -> {:ok, updated_record}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp decode_store(content) do
    case Jason.decode(content) do
      {:ok, %{"format_version" => 1, "issues" => issues}} when is_map(issues) ->
        {:ok, %{format_version: 1, issues: issues}}

      {:ok, decoded} ->
        {:error, {:invalid_shape, decoded}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp encode_store(%{format_version: format_version, issues: issues}) do
    %{"format_version" => format_version, "issues" => issues}
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
