defmodule Indexer.AgentCommTest do
  use ExUnit.Case, async: true

  alias Indexer.AgentComm
  alias Indexer.State.{Event, Jsonl}

  test "reads latest agent result by type and filters" do
    root = tmp_dir()

    append_result(root, "run-1", "test.pass", "worker-1", "PASS", "first")
    append_result(root, "run-2", "test.pass", "worker-2", "FAIL", "second")
    append_result(root, "run-3", "test.pass", "worker-1", "SKIP", "third")

    assert {:ok, latest} = AgentComm.latest_result(root, "test.pass")
    assert latest["agent_run_id"] == "run-3"
    assert latest["outputs"]["gate_result"] == "SKIP"

    assert {:ok, filtered} = AgentComm.latest_result(root, "test.pass", worker_id: "worker-2")
    assert filtered["agent_run_id"] == "run-2"
    assert filtered["outputs"]["report"] == "second"
  end

  test "reads latest report projection" do
    root = tmp_dir()
    append_result(root, "run-1", "test.pass", "worker-1", "PASS", "report body")

    assert {:ok, report} = AgentComm.latest_report(root, "test.pass", worker_id: "worker-1")
    assert report["report"] == "report body"
    assert report["agent_run_id"] == "run-1"
  end

  defp append_result(root, run_id, agent_type, worker_id, gate_result, report) do
    event =
      Event.new("agent_runs", "agent.completed", run_id, %{
        "agent_run_id" => run_id,
        "agent_type" => agent_type,
        "worker_id" => worker_id,
        "work_item_id" => "TASK-1",
        "pipeline_run_id" => "pipeline-1",
        "node_run_id" => "node-1",
        "step_id" => "step",
        "status" => "success",
        "exit_code" => 0,
        "outputs" => %{"gate_result" => gate_result, "report" => report},
        "metadata" => %{}
      })

    Jsonl.append_event!(root, event)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-agent-comm-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
