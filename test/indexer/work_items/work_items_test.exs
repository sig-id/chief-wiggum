defmodule Indexer.WorkItemsTest do
  use ExUnit.Case, async: true

  alias Indexer.WorkItems
  alias Indexer.State.Jsonl

  test "creates and projects work items" do
    root = tmp_dir()

    item =
      WorkItems.create!(root, %{
        id: "TASK-001",
        title: "Build scheduler",
        body: "Implement queue",
        priority: 5
      })

    assert item["status"] == "pending"
    assert {:ok, projected} = WorkItems.get(root, "TASK-001")
    assert projected["title"] == "Build scheduler"
    assert projected["priority"] == 5

    events = root |> Jsonl.ledger_path("work_items") |> Jsonl.read!()
    assert [%{"type" => "work_item.created"}] = events
  end

  test "dependency satisfaction requires merged dependencies" do
    root = tmp_dir()

    WorkItems.create!(root, %{id: "A", title: "Base"})
    WorkItems.create!(root, %{id: "B", title: "Dependent", dependencies: ["A"]})

    assert Enum.map(WorkItems.ready(root), & &1["id"]) == ["A"]

    WorkItems.update_status!(root, "A", "pending_review")
    assert WorkItems.ready(root) == []

    WorkItems.update_status!(root, "A", "merged")
    assert Enum.map(WorkItems.ready(root), & &1["id"]) == ["B"]
  end

  test "updates fields and status append-only" do
    root = tmp_dir()

    WorkItems.create!(root, %{id: "TASK-001", title: "Original"})
    WorkItems.update!(root, "TASK-001", %{title: "Updated", metadata: %{source: "test"}})
    WorkItems.update_status!(root, "TASK-001", "in_progress")

    assert {:ok, item} = WorkItems.get(root, "TASK-001")
    assert item["title"] == "Updated"
    assert item["status"] == "in_progress"
    assert item["metadata"]["source"] == "test"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-work-items-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
