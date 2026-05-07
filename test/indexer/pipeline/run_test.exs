defmodule Indexer.Pipeline.RunTest do
  use ExUnit.Case, async: true

  alias Indexer.Pipeline.Run
  alias Indexer.State.Jsonl

  test "runs a simple passing pipeline and records events" do
    root = tmp_dir()

    pipeline = %{
      name: "simple",
      steps: [
        %{id: "one", agent: "test.pass"},
        %{id: "two", agent: "test.pass"}
      ]
    }

    runner = fn _agent, _context -> "PASS" end

    assert {:ok, result} = Run.run(root, pipeline, runner)
    assert result.status == "completed"
    assert Enum.map(result.history, & &1["step_id"]) == ["one", "two"]

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.count(node_events, &(&1["type"] == "pipeline.node.completed")) == 2
  end

  test "runs inline fix handler before rerunning parent" do
    root = tmp_dir()

    pipeline = %{
      name: "fix-loop",
      steps: [
        %{
          id: "audit",
          agent: "test.audit",
          max: 3,
          on_result: %{
            FIX: %{id: "audit-fix", agent: "test.fix", max: 2}
          }
        }
      ]
    }

    parent = self()

    runner = fn
      "test.audit", _context ->
        send(parent, :audit)

        receive do
          :fixed -> "PASS"
        after
          0 -> "FIX"
        end

      "test.fix", _context ->
        send(parent, :fixed)
        "PASS"
    end

    assert {:ok, result} = Run.run(root, pipeline, runner)
    assert result.status == "completed"
    assert Enum.map(result.history, & &1["step_id"]) == ["audit-fix", "audit"]

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.any?(node_events, &(&1["type"] == "pipeline.inline.completed"))
  end

  test "skips disabled steps without visiting them" do
    root = tmp_dir()

    pipeline = %{
      name: "enabled",
      steps: [
        %{id: "plan", agent: "test.plan", enabled_by: "INDEXER_PLAN_MODE"},
        %{id: "work", agent: "test.pass"}
      ]
    }

    runner = fn
      "test.plan", _context -> flunk("disabled step should not run")
      "test.pass", _context -> "PASS"
    end

    assert {:ok, result} = Run.run(root, pipeline, runner, env: %{})
    assert result.status == "completed"

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.any?(node_events, &(&1["type"] == "pipeline.node.skipped"))
  end

  test "aborts when max visits are exceeded" do
    root = tmp_dir()

    pipeline = %{
      name: "bounded",
      steps: [
        %{id: "loop", agent: "test.fix", max: 2, on_result: %{FIX: %{jump: "self"}}}
      ]
    }

    runner = fn _agent, _context -> "FIX" end

    assert {:ok, result} = Run.run(root, pipeline, runner)
    assert result.status == "completed"
    assert Enum.count(result.history, &(&1["step_id"] == "loop")) == 2

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.any?(node_events, &(&1["type"] == "pipeline.node.max_exceeded"))
  end

  test "circuit breaker escalates repeated UNKNOWN results to FAIL" do
    root = tmp_dir()

    pipeline = %{
      name: "circuit",
      steps: [
        %{id: "extract", agent: "test.unknown", max: 5}
      ]
    }

    runner = fn _agent, _context -> %{} end

    assert {:ok, result} = Run.run(root, pipeline, runner)
    assert result.status == "aborted"

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.any?(node_events, &(&1["type"] == "pipeline.node.circuit_tripped"))
  end

  test "runs pre and post hooks around a step" do
    root = tmp_dir()
    parent = self()

    pipeline = %{
      name: "hooks",
      steps: [
        %{id: "work", agent: "test.pass", hooks: %{pre: ["prepare"], post: ["validate"]}}
      ]
    }

    runner = fn _agent, _context -> "PASS" end

    hook_runner = fn hook, envelope ->
      send(parent, {:hook, hook, envelope["hook"], envelope["node_run"]["step_id"]})
      {:ok, %{"status" => "ok"}}
    end

    assert {:ok, result} = Run.run(root, pipeline, runner, hook_runner: hook_runner)
    assert result.status == "completed"

    assert_received {:hook, "prepare", "pre", "work"}
    assert_received {:hook, "validate", "post", "work"}

    node_events = root |> Jsonl.ledger_path("pipeline_node_runs") |> Jsonl.read!()
    assert Enum.count(node_events, &(&1["type"] == "pipeline.hook.completed")) == 2
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-pipeline-run-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
