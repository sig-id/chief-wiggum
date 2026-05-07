defmodule Indexer.Services.HandlersTest do
  use ExUnit.Case, async: true

  alias Indexer.Services.Handlers
  alias Indexer.WorkItems

  test "scheduler handler reports ready work items" do
    root = tmp_dir()
    WorkItems.create!(root, %{id: "TASK-001", title: "Ready"})

    assert {:ok, result} = Handlers.Scheduler.tick(envelope(root, "scheduler-tick"))
    assert [%{"type" => "work_item.ready", "work_item_id" => "TASK-001"}] = result["decisions"]
  end

  test "worker handler spawns workers for ready work items once" do
    root = tmp_dir()
    WorkItems.create!(root, %{id: "TASK-001", title: "Ready"})

    assert {:ok, result} = Handlers.Workers.spawn(envelope(root, "task-spawner"))
    assert result["spawned"] == 1
    assert [%{"worker_id" => worker_id}] = result["workers"]

    assert {:ok, item} = WorkItems.get(root, "TASK-001")
    assert item["status"] == "in_progress"

    assert {:ok, second} = Handlers.Workers.spawn(envelope(root, "task-spawner"))
    assert second["spawned"] == 0

    assert worker_id =~ "worker-TASK-001"
  end

  defp envelope(root, service_id) do
    %{
      "service" => %{"id" => service_id},
      "context" => %{"project_root" => root}
    }
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-service-handlers-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
