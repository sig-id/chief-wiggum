defmodule Indexer.State.Projections do
  @moduledoc """
  Disposable projection materializer.

  Projection files are caches. They are always rebuildable from JSONL ledgers and
  control branch exports should treat them as snapshots, not source of truth.
  """

  @doc """
  Returns the projection directory for a project.
  """
  @spec dir(Path.t()) :: Path.t()
  def dir(project_root) when is_binary(project_root) do
    project_root
    |> Indexer.ledger_dir()
    |> Path.join("projections")
  end

  @doc """
  Rebuilds the standard projection set.
  """
  @spec rebuild!(Path.t()) :: map()
  def rebuild!(project_root) when is_binary(project_root) do
    projection_dir = dir(project_root)
    File.mkdir_p!(projection_dir)

    projections = %{
      "work_items.current.json" => Indexer.WorkItems.current(project_root),
      "workers.current.json" => Indexer.Workers.current(project_root),
      "change_sets.current.json" => Indexer.ChangeSets.current(project_root),
      "services.current.json" => Indexer.Services.State.current(project_root),
      "effects.current.json" => Indexer.Effects.Outbox.current(project_root),
      "queue.current.json" => queue_projection(project_root)
    }

    written =
      Enum.map(projections, fn {filename, data} ->
        path = Path.join(projection_dir, filename)
        File.write!(path, JSON.encode!(Indexer.State.Json.normalize(data)) <> "\n")
        path
      end)

    %{
      "projection_dir" => projection_dir,
      "written" => written,
      "count" => length(written)
    }
  end

  defp queue_projection(project_root) do
    %{
      "ready_work_items" => Indexer.WorkItems.ready(project_root),
      "ready_change_sets" => Indexer.ChangeSets.ready_for_merge(project_root),
      "merge_batch" =>
        project_root
        |> Indexer.ChangeSets.ready_for_merge()
        |> Indexer.ChangeSets.MergePlanner.select_batch()
    }
  end
end
