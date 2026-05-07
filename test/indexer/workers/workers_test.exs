defmodule Indexer.WorkersTest do
  use ExUnit.Case, async: true

  alias Indexer.Workers
  alias Indexer.Workers.Lifecycle

  test "spawns worker and projects workspace metadata" do
    root = tmp_dir()

    worker =
      Workers.spawn!(root, %{
        id: "worker-TASK-001-1",
        work_item_id: "TASK-001",
        pipeline: "default",
        target_ref: "main"
      })

    assert worker["state"] == "needs_merge"
    assert worker["work_branch"] =~ "indexer/work/TASK-001"
    assert {:ok, projected} = Workers.get(root, "worker-TASK-001-1")
    assert projected["workspace_path"] =~ ".indexer/worktrees/worker-TASK-001-1/workspace"
  end

  test "applies lifecycle transitions from the formal model" do
    root = tmp_dir()
    Workers.spawn!(root, %{id: "worker-1", work_item_id: "TASK-001"})

    Workers.transition!(root, "worker-1", "merge.start")
    Workers.transition!(root, "worker-1", "merge.conflict")
    Workers.transition!(root, "worker-1", "conflict.needs_resolve")
    Workers.transition!(root, "worker-1", "resolve.started")
    Workers.transition!(root, "worker-1", "resolve.succeeded")

    assert {:ok, worker} = Workers.get(root, "worker-1")
    assert worker["state"] == "needs_merge"

    Workers.transition!(root, "worker-1", "merge.start")
    Workers.transition!(root, "worker-1", "merge.succeeded")

    assert {:ok, worker} = Workers.get(root, "worker-1")
    assert worker["state"] == "merged"
  end

  test "rejects invalid lifecycle transitions" do
    assert {:error, {:invalid_transition, "none", "merge.start"}} =
             Lifecycle.next_state("none", "merge.start")
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "indexer-workers-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
