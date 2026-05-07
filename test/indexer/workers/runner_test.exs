defmodule Indexer.Workers.RunnerTest do
  use ExUnit.Case, async: true

  alias Indexer.Workers
  alias Indexer.Workers.Runner

  test "runs a worker pipeline and records pipeline metadata" do
    root = tmp_dir()

    Workers.spawn!(root, %{
      id: "worker-1",
      work_item_id: "TASK-001",
      pipeline: "test"
    })

    pipeline = %{
      name: "worker-test",
      steps: [
        %{id: "one", agent: "test.pass"}
      ]
    }

    agent_runner = fn "test.pass", context ->
      assert context["project_root"] == root
      "PASS"
    end

    assert {:ok, result} =
             Runner.run(root, "worker-1", pipeline: pipeline, agent_runner: agent_runner)

    assert result.status == "completed"
    assert {:ok, worker} = Workers.get(root, "worker-1")
    assert worker["pipeline_status"] == "completed"
    assert is_binary(worker["pipeline_run_id"])
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-worker-runner-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
