defmodule Indexer.ChangeSetsTest do
  use ExUnit.Case, async: true

  alias Indexer.ChangeSets

  test "creates and projects change sets" do
    root = tmp_dir()

    change_set =
      ChangeSets.create!(root, %{
        id: "cs-1",
        work_item_id: "TASK-001",
        worker_id: "worker-1",
        target_ref: "main",
        work_branch: "indexer/work/TASK-001/worker-1",
        affected_files: ["lib/a.ex"]
      })

    assert change_set["status"] == "draft"
    assert {:ok, projected} = ChangeSets.get(root, "cs-1")
    assert projected["affected_files"] == ["lib/a.ex"]
  end

  test "tracks ready, conflict, and merged status" do
    root = tmp_dir()

    ChangeSets.create!(root, base_change_set("cs-1"))
    ChangeSets.mark_ready!(root, "cs-1")
    assert [%{"id" => "cs-1"}] = ChangeSets.ready_for_merge(root)

    ChangeSets.mark_conflict!(root, "cs-1", %{"files" => ["lib/a.ex"]})
    assert ChangeSets.ready_for_merge(root) == []
    assert {:ok, conflicted} = ChangeSets.get(root, "cs-1")
    assert conflicted["status"] == "merge_conflict"
    assert conflicted["conflict"]["files"] == ["lib/a.ex"]

    ChangeSets.mark_merged!(root, "cs-1", "abc123")
    assert {:ok, merged} = ChangeSets.get(root, "cs-1")
    assert merged["status"] == "merged"
    assert merged["merge_sha"] == "abc123"
  end

  defp base_change_set(id) do
    %{
      id: id,
      work_item_id: "TASK-001",
      worker_id: "worker-1",
      target_ref: "main",
      work_branch: "indexer/work/TASK-001/worker-1",
      affected_files: ["lib/a.ex"]
    }
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-change-sets-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
