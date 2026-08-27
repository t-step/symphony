defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.{Config.Schema, Local.Adapter, Local.Init, LogFile, Workflow}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @local_tracker_init_switches [reset: :boolean]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result()),
          load_workflow: (String.t() -> {:ok, Workflow.loaded_workflow()} | {:error, term()}),
          local_tracker_init: (Path.t(), keyword() -> {:ok, atom()} | {:error, term()})
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    main(args, fn -> Application.ensure_all_started(:symphony_elixir) end)
  end

  @doc false
  @spec main([String.t()], (-> ensure_started_result())) :: no_return()
  def main(args, ensure_all_started) do
    case evaluate(args, runtime_deps(ensure_all_started)) do
      :ok ->
        wait_for_shutdown()

      {:done, message} ->
        IO.puts(message)
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def evaluate(args, deps \\ runtime_deps())

  @spec evaluate([String.t()], deps()) :: :ok | {:done, String.t()} | {:error, String.t()}
  def evaluate(["local-tracker", "init" | rest], deps) do
    run_local_tracker_init(rest, deps)
  end

  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"
  end

  @spec local_tracker_usage_message() :: String.t()
  defp local_tracker_usage_message do
    "Usage: symphony local-tracker init [--reset] [path-to-WORKFLOW.md]"
  end

  defp run_local_tracker_init(args, deps) do
    case OptionParser.parse(args, strict: @local_tracker_init_switches) do
      {opts, [], []} ->
        do_local_tracker_init(Path.expand("WORKFLOW.md"), opts, deps)

      {opts, [workflow_path], []} ->
        do_local_tracker_init(Path.expand(workflow_path), opts, deps)

      _ ->
        {:error, local_tracker_usage_message()}
    end
  end

  defp do_local_tracker_init(expanded_path, opts, deps) do
    with {:ok, workflow} <- deps.load_workflow.(expanded_path),
         {:ok, settings} <- Schema.parse(workflow.config),
         {:ok, provider_path} <- local_tracker_provider_path(settings, expanded_path) do
      reset? = Keyword.get(opts, :reset, false)

      case deps.local_tracker_init.(provider_path, reset: reset?) do
        {:ok, outcome} ->
          {:done, "Local tracker #{format_local_tracker_outcome(outcome)} at #{provider_path}"}

        {:error, reason} ->
          {:error, "Failed to initialize local tracker at #{provider_path}: #{format_local_tracker_error(reason)}"}
      end
    else
      {:error, {:wrong_tracker_kind, kind}} ->
        {:error, "tracker.kind must be \"local\" to run local-tracker init (got #{inspect(kind)})"}

      {:error, reason} ->
        {:error, format_workflow_load_error(expanded_path, reason)}
    end
  end

  defp local_tracker_provider_path(%{tracker: %{kind: "local"} = tracker}, workflow_path) do
    {:ok, Adapter.resolve_provider_path(tracker.provider, Path.dirname(workflow_path))}
  end

  defp local_tracker_provider_path(%{tracker: %{kind: kind}}, _workflow_path) do
    {:error, {:wrong_tracker_kind, kind}}
  end

  defp format_local_tracker_outcome(:initialized), do: "initialized"
  defp format_local_tracker_outcome(:reset), do: "reset and reinitialized"

  defp format_local_tracker_error(:already_established) do
    "already established; pass --reset to overwrite"
  end

  defp format_local_tracker_error({:local_tracker_corrupt, reason}) do
    "existing database does not open cleanly (#{inspect(reason)}); resolve manually or pass --reset"
  end

  defp format_local_tracker_error(reason), do: inspect(reason)

  defp format_workflow_load_error(path, {:missing_workflow_file, _path, reason}) do
    "Missing WORKFLOW.md at #{path}: #{inspect(reason)}"
  end

  defp format_workflow_load_error(_path, {:invalid_workflow_config, message}) do
    "Invalid WORKFLOW.md config: #{message}"
  end

  defp format_workflow_load_error(_path, :workflow_front_matter_not_a_map) do
    "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"
  end

  defp format_workflow_load_error(_path, {:workflow_parse_error, reason}) do
    "Failed to parse WORKFLOW.md: #{inspect(reason)}"
  end

  defp format_workflow_load_error(_path, reason), do: "Failed to load WORKFLOW.md: #{inspect(reason)}"

  @spec runtime_deps() :: deps()
  defp runtime_deps(ensure_all_started \\ fn -> Application.ensure_all_started(:symphony_elixir) end) do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: ensure_all_started,
      load_workflow: &Workflow.load/1,
      local_tracker_init: &Init.run/2
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
