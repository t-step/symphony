defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Local
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :settings, :structural]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :settings)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, %State{settings: settings}} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns the structural (restart-only) configuration selection captured once
  at process start, unaffected by any later `WORKFLOW.md` reload (IV-005).
  """
  @spec structural_settings() :: {:ok, map()} | {:error, term()}
  def structural_settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :structural_settings)

      _ ->
        path = Workflow.workflow_file_path()

        case load_state(path) do
          {:ok, %State{settings: settings}} -> {:ok, compute_structural(settings, path)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        structural = compute_structural(state.settings, state.path)
        :ok = ensure_local_store(structural)
        schedule_poll()
        {:ok, %{state | structural: structural}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  def handle_call(:structural_settings, _from, %State{structural: structural} = state) do
    {:reply, {:ok, structural}, state}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  # Threads the already-pinned tracker_kind through so Schema.parse/2's kind-dependent
  # normalization (Linear secret resolution, active/terminal state defaults) stays keyed off
  # the structural pin rather than whatever tracker.kind this reload just read live — otherwise
  # a live tracker.kind edit could change the still-pinned adapter's effective settings before
  # a restart, even though adapter() itself correctly stays pinned.
  defp reload_path(path, state) do
    case load_state(path, state.structural.tracker_kind) do
      {:ok, new_state} ->
        {:ok, %{new_state | structural: state.structural}}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path, structural_tracker_kind \\ nil) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config, structural_tracker_kind),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end

  # Structural (restart-only) selections, per IV-005/research.md R9/R9a. Computed once at
  # process start (`init/1`) and preserved unchanged across every later reload (`reload_path/2`)
  # regardless of how many times `WORKFLOW.md` changes afterward. `agent_execution_kind` is added
  # to this map by a later task as its prerequisite field lands.
  defp compute_structural(%Schema{tracker: %{kind: "local"} = tracker} = _settings, path) do
    workflow_dir = path |> Path.expand() |> Path.dirname()

    %{
      tracker_kind: tracker.kind,
      tracker_provider_path: Local.Adapter.resolve_provider_path(tracker.provider, workflow_dir)
    }
  end

  defp compute_structural(%Schema{} = settings, _path) do
    %{tracker_kind: settings.tracker.kind}
  end

  # `Local.Store` is a named singleton, started only when `tracker.kind: local` is the active
  # structural selection (research.md R1a) — and only here, at `WorkflowStore.init/1`, so its
  # lifecycle is tied to the same restart boundary as the structural pin above (IV-005/research.md
  # R9a): `start_link/1` links the new process to this GenServer, so a `WorkflowStore` restart
  # (the only event that may change `tracker_provider_path`) always tears down and restarts
  # `Local.Store` too, while an ordinary dynamic reload (`force_reload/0`, the poll tick) never
  # touches it.
  defp ensure_local_store(%{tracker_kind: "local", tracker_provider_path: path}) do
    case Local.Store.start_link(path: path, name: Local.Store) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_local_store(_structural), do: :ok
end
