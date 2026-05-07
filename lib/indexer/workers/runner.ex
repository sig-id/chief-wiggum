defmodule Indexer.Workers.Runner do
  @moduledoc """
  Runs a worker's configured pipeline in its workspace.
  """

  @doc """
  Starts a worker pipeline asynchronously under `Indexer.WorkerSupervisor`.
  """
  @spec start(Path.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(project_root, worker_id, opts \\ []) do
    child = %{
      id: {__MODULE__, worker_id, System.unique_integer([:positive])},
      start: {Task, :start_link, [fn -> run(project_root, worker_id, opts) end]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(Indexer.WorkerSupervisor, child)
  end

  @doc """
  Runs a worker pipeline synchronously.
  """
  @spec run(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(project_root, worker_id, opts \\ [])
      when is_binary(project_root) and is_binary(worker_id) do
    with {:ok, worker} <- Indexer.Workers.get(project_root, worker_id),
         {:ok, pipeline} <- load_pipeline(worker, opts) do
      Indexer.Workers.update!(project_root, worker_id, %{
        "pipeline_status" => "running",
        "pipeline_started_at" => timestamp()
      })

      agent_runner =
        Keyword.get_lazy(opts, :agent_runner, fn ->
          Indexer.Agents.Runner.runner(project_root, opts)
        end)

      pipeline_opts =
        opts
        |> Keyword.put(:correlation_id, worker["work_item_id"])
        |> Keyword.put(:actor, %{"type" => "worker", "id" => worker_id})

      case Indexer.Pipeline.Run.run(project_root, pipeline, agent_runner, pipeline_opts) do
        {:ok, result} ->
          Indexer.Workers.update!(project_root, worker_id, %{
            "pipeline_status" => result.status,
            "pipeline_run_id" => result.pipeline_run_id,
            "pipeline_completed_at" => timestamp()
          })

          {:ok, result}

        {:error, reason} ->
          Indexer.Workers.update!(project_root, worker_id, %{
            "pipeline_status" => "failed",
            "pipeline_error" => inspect(reason),
            "pipeline_completed_at" => timestamp()
          })

          {:error, reason}
      end
    end
  end

  defp load_pipeline(worker, opts) do
    case Keyword.get(opts, :pipeline) do
      nil ->
        path =
          opts
          |> Keyword.get(
            :pipeline_path,
            Path.expand("config/pipelines/#{worker["pipeline"]}.json", File.cwd!())
          )

        {:ok, Indexer.Pipeline.Loader.load_file!(path)}

      pipeline when is_map(pipeline) ->
        {:ok, Indexer.State.Json.normalize(pipeline)}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
