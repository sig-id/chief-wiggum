defmodule Indexer.Effects.ExecutorTest do
  use ExUnit.Case, async: true

  alias Indexer.Effects.{Effect, Executor, Outbox}
  alias Indexer.WorkItems

  test "drains work item create effects and marks them completed" do
    root = tmp_dir()

    effect =
      Effect.new("work_item.create", "work_item", "TASK-001", %{
        "id" => "TASK-001",
        "title" => "Created by effect"
      })

    Outbox.record_pending!(root, effect)

    assert {:ok, result} = Executor.drain(root)
    assert result["attempted"] == 1
    assert result["completed"] == 1

    assert {:ok, item} = WorkItems.get(root, "TASK-001")
    assert item["title"] == "Created by effect"

    assert [%{"status" => "completed"}] = root |> Outbox.current() |> Map.values()
  end

  test "marks unsupported effects failed" do
    root = tmp_dir()
    effect = Effect.new("unknown.effect", "test", "scope-1", %{})
    Outbox.record_pending!(root, effect)

    assert {:ok, result} = Executor.drain(root)
    assert result["failed"] == 1

    assert [%{"status" => "failed", "attempts" => 1}] = root |> Outbox.current() |> Map.values()
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-effect-executor-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
