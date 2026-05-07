defmodule Indexer.Services.Handlers.Scheduler do
  @moduledoc """
  Default worker scheduler service handlers.
  """

  def tick(envelope) do
    project_root = get_in(envelope, ["context", "project_root"])
    ready = Indexer.WorkItems.ready(project_root)

    {:ok,
     %{
       "status" => "ok",
       "handler" => __MODULE__ |> Atom.to_string(),
       "service_id" => get_in(envelope, ["service", "id"]),
       "decisions" =>
         Enum.map(ready, fn work_item ->
           %{
             "type" => "work_item.ready",
             "work_item_id" => work_item["id"],
             "priority" => Map.get(work_item, "priority", 0)
           }
         end)
     }}
  end
end
