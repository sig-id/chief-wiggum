defmodule Indexer.Services.Handlers.Workers do
  @moduledoc """
  Default worker lifecycle service handlers.
  """

  def spawn(envelope) do
    project_root = get_in(envelope, ["context", "project_root"])
    existing_workers = Indexer.Workers.current(project_root)

    spawned =
      project_root
      |> Indexer.WorkItems.ready()
      |> Enum.reject(&active_worker_for?(existing_workers, &1["id"]))
      |> Enum.map(fn work_item ->
        worker =
          Indexer.Workers.spawn!(project_root, %{
            "work_item_id" => work_item["id"],
            "target_ref" => work_item["target_ref"],
            "pipeline" => get_in(envelope, ["service", "config", "pipeline"]) || "default"
          })

        Indexer.WorkItems.update_status!(project_root, work_item["id"], "in_progress",
          reason: "worker_spawned",
          correlation_id: worker["id"]
        )

        %{"worker_id" => worker["id"], "work_item_id" => work_item["id"]}
      end)

    {:ok,
     %{
       "status" => "ok",
       "handler" => __MODULE__ |> Atom.to_string(),
       "service_id" => get_in(envelope, ["service", "id"]),
       "spawned" => length(spawned),
       "workers" => spawned
     }}
  end

  defp active_worker_for?(workers, work_item_id) do
    workers
    |> Map.values()
    |> Enum.any?(fn worker ->
      worker["work_item_id"] == work_item_id and worker["state"] not in ["merged", "failed"]
    end)
  end
end
