defmodule Indexer.Services.RunnerTest do
  use ExUnit.Case, async: true

  alias Indexer.Services.{Runner, State}
  alias Indexer.State.Jsonl

  test "runs an allowlisted function service and records lifecycle events" do
    root = tmp_dir()

    service = %{
      id: "validate-control",
      phase: "startup",
      schedule: %{type: "tick"},
      execution: %{
        type: "function",
        module: "Indexer.Services.Handlers.Control",
        function: "validate"
      }
    }

    assert {:ok, result} = Runner.run(root, service)
    assert result["status"] == "success"

    events = root |> Jsonl.ledger_path("services") |> Jsonl.read!()
    assert Enum.map(events, & &1["type"]) == ["service.started", "service.completed"]
    assert State.get(root, "validate-control")["run_count"] == 1
  end

  test "runs argv command services without shell evaluation by default" do
    root = tmp_dir()

    service = %{
      id: "command",
      schedule: %{type: "tick"},
      execution: %{type: "command", command: ["printf", "ok"]}
    }

    assert {:ok, result} = Runner.run(root, service)
    assert result["output"]["stdout"] == "ok"
  end

  test "skips a running singleton service according to concurrency policy" do
    root = tmp_dir()

    service = %{
      id: "singleton",
      schedule: %{type: "tick"},
      execution: %{type: "command", command: ["printf", "ok"]},
      concurrency: %{max_instances: 1, if_running: "skip"}
    }

    append_started(root, "singleton")

    assert {:ok, result} = Runner.run(root, service)
    assert result["status"] == "skipped"
    assert result["reason"] == "already_running"
  end

  defp append_started(root, service_id) do
    event =
      Indexer.State.Event.new("services", "service.started", "service:#{service_id}", %{
        service_id: service_id,
        run_id: "run-1",
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      })

    Jsonl.append_event!(root, event)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-service-runner-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
