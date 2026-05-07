defmodule Indexer.Agents.Runner do
  @moduledoc """
  Executes configured agents for pipeline steps.

  The runner owns deterministic orchestration around the external runtime:
  registry resolution, prompt rendering, lifecycle JSONL records, hook execution,
  result extraction, and normalized output returned to the pipeline engine.
  """

  alias Indexer.Agents.{Registry, Result}
  alias Indexer.Pipeline.ResultMappings
  alias Indexer.Runtime.Invocation
  alias Indexer.State.{Event, Jsonl}

  @type output :: %{required(String.t()) => term()}

  @doc """
  Returns a two-argument function suitable for `Indexer.Pipeline.Run`.
  """
  @spec runner(Path.t(), keyword()) :: (String.t(), map() -> {:ok, output()} | {:error, term()})
  def runner(project_root, opts \\ []) when is_binary(project_root) do
    fn agent_type, context -> run(project_root, agent_type, context, opts) end
  end

  @doc """
  Runs one agent invocation and returns a pipeline-compatible output map.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, output()} | {:error, term()}
  def run(project_root, agent_type, context, opts \\ [])
      when is_binary(project_root) and is_binary(agent_type) and is_map(context) do
    context = Indexer.State.Json.normalize(context)
    registry = Keyword.get_lazy(opts, :registry, fn -> load_registry(opts) end)
    overrides = Map.get(context, "config", %{})

    with {:ok, resolved} <- Registry.resolve(registry, agent_type, overrides) do
      execute_resolved(project_root, resolved, context, opts)
    end
  end

  defp load_registry(opts) do
    opts
    |> Keyword.get(:registry_path, default_registry_path())
    |> Registry.from_file!()
  end

  defp default_registry_path do
    Path.expand("config/agents.json", File.cwd!())
  end

  defp execute_resolved(project_root, resolved, context, opts) do
    agent_run_id = new_agent_run_id()
    started_at = timestamp()
    context = Map.put(context, "agent_run_id", agent_run_id)

    append_agent_event(project_root, "agent.started", agent_run_id, %{
      "agent_type" => resolved.type,
      "pipeline_run_id" => context["pipeline_run_id"],
      "node_run_id" => context["node_run_id"],
      "step_id" => context["step_id"],
      "worker_id" => worker_id(context),
      "work_item_id" => work_item_id(context),
      "mode" => resolved.definition.mode,
      "runtime" => resolved.runtime,
      "config" => snapshot_config(resolved)
    })

    case do_execute(project_root, resolved, context, agent_run_id, opts) do
      {:ok, output} ->
        completed_at = timestamp()
        gate_result = get_in(output, ["outputs", "gate_result"])
        mapping = resolve_mapping(gate_result, resolved.result_mappings)

        append_agent_event(project_root, "agent.completed", agent_run_id, %{
          "agent_run_id" => agent_run_id,
          "agent_type" => resolved.type,
          "pipeline_run_id" => context["pipeline_run_id"],
          "node_run_id" => context["node_run_id"],
          "step_id" => context["step_id"],
          "worker_id" => worker_id(context),
          "work_item_id" => work_item_id(context),
          "status" => mapping["status"],
          "exit_code" => mapping["exit_code"],
          "started_at" => started_at,
          "completed_at" => completed_at,
          "duration_seconds" => duration_seconds(started_at, completed_at),
          "outputs" => output["outputs"],
          "artifacts" => output["artifacts"],
          "effects" => output["effects"],
          "errors" => output["errors"],
          "metadata" => output["metadata"]
        })

        {:ok, output}

      {:error, reason} ->
        append_agent_event(project_root, "agent.failed", agent_run_id, %{
          "agent_run_id" => agent_run_id,
          "agent_type" => resolved.type,
          "pipeline_run_id" => context["pipeline_run_id"],
          "node_run_id" => context["node_run_id"],
          "step_id" => context["step_id"],
          "worker_id" => worker_id(context),
          "work_item_id" => work_item_id(context),
          "status" => "failure",
          "exit_code" => 5,
          "started_at" => started_at,
          "completed_at" => timestamp(),
          "outputs" => %{"gate_result" => "UNKNOWN"},
          "artifacts" => [],
          "effects" => [],
          "errors" => [%{"reason" => inspect(reason)}],
          "metadata" => %{}
        })

        {:error, reason}
    end
  end

  defp do_execute(project_root, resolved, context, agent_run_id, opts) do
    hook_runner = Keyword.get(opts, :hook_runner, &Indexer.Hooks.Executor.run/2)

    try do
      with :ok <- validate_required_paths(project_root, resolved.definition, context),
           {:ok, prepared_context, prepared_artifacts} <-
             run_agent_hooks(
               project_root,
               resolved,
               agent_run_id,
               "prepare",
               context,
               hook_runner
             ),
           objective <- render_objective(resolved, prepared_context),
           {:ok, checked_context, checked_artifacts} <-
             run_agent_hooks(
               project_root,
               resolved,
               agent_run_id,
               "before_turn",
               prepared_context,
               hook_runner
             ),
           invocation <-
             build_invocation(project_root, resolved, checked_context, objective, agent_run_id),
           {:ok, runtime_result} <- runtime_invoke(project_root, invocation, opts),
           {:ok, output_context, validation_artifacts} <-
             validate_output(
               project_root,
               resolved,
               agent_run_id,
               runtime_result,
               checked_context,
               hook_runner
             ) do
        text = runtime_result.text

        gate_result =
          Map.get(output_context, "gate_result") ||
            Result.extract_gate_result(text, resolved.definition)

        report = Result.extract_report(text, resolved.definition)

        {:ok,
         %{
           "agent_run_id" => agent_run_id,
           "outputs" => %{
             "gate_result" => gate_result,
             "report" => report,
             "text" => text
           },
           "artifacts" => prepared_artifacts ++ checked_artifacts ++ validation_artifacts,
           "effects" => [],
           "errors" => result_errors(gate_result, resolved.definition.valid_results),
           "metadata" => %{
             "runtime" => invocation.runtime,
             "runtime_session_id" => runtime_result.session.runtime_session_id,
             "events_count" => length(runtime_result.events)
           }
         }}
      end
    after
      run_agent_hooks(project_root, resolved, agent_run_id, "cleanup", context, hook_runner)
    end
  end

  defp runtime_invoke(project_root, invocation, opts) do
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    case Keyword.get(opts, :runtime_runner) do
      nil -> Indexer.Runtime.invoke(project_root, invocation, runtime_opts)
      runner when is_function(runner, 3) -> runner.(project_root, invocation, runtime_opts)
    end
  end

  defp render_objective(%{markdown: nil, definition: definition}, context) do
    valid_results = Enum.join(definition.valid_results, ", ")

    %{
      "system" =>
        "You are #{definition.type}. #{definition.description}\nReturn one gate result from: #{valid_results}.",
      "user" => Map.get(context, "objective", "Run pipeline step #{context["step_id"]}."),
      "continuation" => nil,
      "output_schema" => nil
    }
  end

  defp render_objective(%{markdown: markdown}, context) do
    %{
      "system" => Indexer.Agents.Markdown.render(markdown, :system, context),
      "user" => Indexer.Agents.Markdown.render(markdown, :user, context),
      "continuation" => Indexer.Agents.Markdown.render(markdown, :continuation, context),
      "output_schema" => nil
    }
  end

  defp build_invocation(project_root, resolved, context, objective, agent_run_id) do
    runtime = Map.get(resolved.runtime, "adapter", "codex")

    %Invocation{
      agent_run_id: agent_run_id,
      agent_type: resolved.type,
      runtime: runtime,
      mode: Map.get(resolved.runtime, "mode", "cli_text"),
      workspace_path: workspace_path(project_root, context),
      objective: objective,
      session: session_context(resolved, context),
      policy: policy(resolved, context),
      runtime_config: resolved.runtime,
      context: Map.merge(context, %{"agent_type" => resolved.type}),
      artifacts: []
    }
  end

  defp policy(resolved, context) do
    %{
      "approval_policy" =>
        get_in(resolved.config, ["policy", "approval_policy"]) || "unless_trusted",
      "sandbox" => if(resolved.definition.readonly, do: "readonly", else: "workspace_write"),
      "writable_roots" => Map.get(context, "writable_roots", []),
      "network" => Map.get(context, "network", false),
      "timeout_seconds" => resolved.timeout_seconds || 10_800,
      "max_turns" => resolved.max_turns || 50,
      "max_iterations" => resolved.max_iterations || 1
    }
  end

  defp session_context(resolved, context) do
    %{
      "resume" => resolved.definition.mode == "resume",
      "session_from" => resolved.definition.session_from,
      "runtime_session_id" => Map.get(context, "runtime_session_id"),
      "parent_session_id" => get_in(context, ["parent", "session_id"])
    }
  end

  defp validate_output(project_root, resolved, agent_run_id, runtime_result, context, hook_runner) do
    context =
      Map.merge(context, %{
        "runtime" => %{
          "text" => runtime_result.text,
          "session" => Indexer.State.Json.normalize(runtime_result.session),
          "events" => runtime_result.events
        },
        "gate_result" => Result.extract_gate_result(runtime_result.text, resolved.definition)
      })

    run_agent_hooks(project_root, resolved, agent_run_id, "validate_output", context, hook_runner)
  end

  defp run_agent_hooks(project_root, resolved, agent_run_id, hook_name, context, hook_runner) do
    resolved.definition.hooks
    |> Map.get(hook_name, [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, context, []}, fn hook, {:ok, acc_context, acc_artifacts} ->
      envelope = hook_envelope(project_root, resolved, agent_run_id, hook_name, acc_context)

      case hook_runner.(hook, envelope) do
        {:ok, result} ->
          append_agent_event(project_root, "agent.hook.completed", agent_run_id, %{
            "hook" => hook_name,
            "agent_type" => resolved.type,
            "result" => result
          })

          status = Map.get(result, "status", "ok")
          next_context = Registry.deep_merge(acc_context, Map.get(result, "context", %{}))
          artifacts = acc_artifacts ++ Map.get(result, "artifacts", [])

          if status == "hard_fail" do
            {:halt, {:error, {:hook_failed, hook_name, result}}}
          else
            {:cont, {:ok, next_context, artifacts}}
          end

        {:error, error} ->
          append_agent_event(project_root, "agent.hook.failed", agent_run_id, %{
            "hook" => hook_name,
            "agent_type" => resolved.type,
            "error" => error
          })

          {:halt, {:error, {:hook_failed, hook_name, error}}}
      end
    end)
  end

  defp hook_envelope(project_root, resolved, agent_run_id, hook_name, context) do
    %{
      "hook" => hook_name,
      "agent_id" => resolved.type,
      "agent_run" => %{"id" => agent_run_id},
      "work_item" => Map.get(context, "work_item", %{}),
      "worker" => Map.get(context, "worker", %{}),
      "pipeline_run" => %{"id" => context["pipeline_run_id"]},
      "node_run" => %{"id" => context["node_run_id"], "step_id" => context["step_id"]},
      "workspace" => %{"path" => workspace_path(project_root, context)},
      "repository" => %{"project_root" => project_root},
      "context" => context,
      "artifacts" => [],
      "config" => resolved.config
    }
  end

  defp validate_required_paths(project_root, definition, context) do
    missing =
      definition.required_paths
      |> Enum.map(&resolve_required_path(project_root, context, &1))
      |> Enum.reject(&File.exists?/1)

    case missing do
      [] -> :ok
      paths -> {:error, {:missing_required_paths, paths}}
    end
  end

  defp resolve_required_path(project_root, context, "workspace"),
    do: workspace_path(project_root, context)

  defp resolve_required_path(project_root, _context, "project_dir"), do: project_root
  defp resolve_required_path(project_root, _context, "project_root"), do: project_root

  defp resolve_required_path(project_root, _context, path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_root, path)
  end

  defp workspace_path(project_root, context) do
    Map.get(context, "workspace") || Map.get(context, "project_root") || project_root
  end

  defp worker_id(context), do: Map.get(context, "worker_id") || get_in(context, ["worker", "id"])

  defp work_item_id(context) do
    Map.get(context, "work_item_id") || get_in(context, ["work_item", "id"])
  end

  defp resolve_mapping(gate_result, result_mappings) do
    case ResultMappings.resolve(gate_result || "UNKNOWN", result_mappings, %{}) do
      {:ok, mapping} -> mapping
      {:error, :unknown_result} -> %{"status" => "unknown", "exit_code" => 1}
    end
  end

  defp result_errors(gate_result, valid_results) do
    if gate_result in valid_results do
      []
    else
      [%{"reason" => "invalid_gate_result", "gate_result" => gate_result}]
    end
  end

  defp append_agent_event(project_root, type, agent_run_id, payload) do
    event =
      Event.new("agent_runs", type, agent_run_id, payload,
        actor: %{"type" => "agent-runner", "id" => "indexer"},
        correlation_id: Map.get(payload, "pipeline_run_id")
      )

    Jsonl.append_event!(project_root, event)
  end

  defp snapshot_config(resolved) do
    Map.take(resolved.config, [
      "max_iterations",
      "max_turns",
      "timeout_seconds",
      "runtime",
      "result_mappings"
    ])
  end

  defp duration_seconds(started_at, completed_at) do
    with {:ok, started, _} <- DateTime.from_iso8601(started_at),
         {:ok, completed, _} <- DateTime.from_iso8601(completed_at) do
      DateTime.diff(completed, started, :second)
    else
      _ -> nil
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp new_agent_run_id, do: "agent_run_#{System.unique_integer([:positive, :monotonic])}"
end
