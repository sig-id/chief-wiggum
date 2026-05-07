defmodule Indexer.State.ProjectionsTest do
  use ExUnit.Case, async: true

  alias Indexer.State.Projections

  test "rebuilds disposable projection files from ledgers" do
    root = tmp_dir()

    Indexer.WorkItems.create!(root, %{id: "TASK-001", title: "Projected"})
    Indexer.Workers.spawn!(root, %{id: "worker-1", work_item_id: "TASK-001"})

    result = Projections.rebuild!(root)

    assert result["count"] == 6
    assert File.exists?(Path.join(result["projection_dir"], "work_items.current.json"))
    assert File.exists?(Path.join(result["projection_dir"], "workers.current.json"))
    assert File.exists?(Path.join(result["projection_dir"], "queue.current.json"))

    queue =
      result["projection_dir"]
      |> Path.join("queue.current.json")
      |> File.read!()
      |> JSON.decode!()

    assert is_list(queue["ready_work_items"])
    assert is_list(queue["merge_batch"])
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-projections-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
