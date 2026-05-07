defmodule Indexer.Agents.RunnerTest do
  use ExUnit.Case, async: true

  alias Indexer.Agents.{Registry, Runner}
  alias Indexer.Pipeline.Run
  alias Indexer.Runtime.Session
  alias Indexer.State.Jsonl

  test "runs an agent through the runtime facade contract and records agent results" do
    root = tmp_dir()
    parent = self()
    registry = registry()

    runtime_runner = fn _root, invocation, _opts ->
      send(parent, {:invocation, invocation})

      {:ok,
       %{
         session: session(text: "<result>PASS</result><report>done</report>"),
         text: "<result>PASS</result><report>done</report>",
         events: []
       }}
    end

    assert {:ok, output} =
             Runner.run(
               root,
               "test.pass",
               %{
                 "pipeline_run_id" => "pipeline-1",
                 "node_run_id" => "node-1",
                 "step_id" => "step"
               },
               registry: registry,
               runtime_runner: runtime_runner
             )

    assert output["outputs"]["gate_result"] == "PASS"
    assert output["outputs"]["report"] == "done"
    assert output["metadata"]["runtime"] == "codex"

    assert_received {:invocation, invocation}
    assert invocation.agent_run_id == output["agent_run_id"]
    assert invocation.objective["system"] =~ "test.pass"

    events = root |> Jsonl.ledger_path("agent_runs") |> Jsonl.read!()
    assert Enum.any?(events, &(&1["type"] == "agent.started"))
    assert Enum.any?(events, &(&1["type"] == "agent.completed"))
  end

  test "bridges the ordered pipeline runner to configured agent execution" do
    root = tmp_dir()
    registry = registry()

    runtime_runner = fn _root, _invocation, _opts ->
      {:ok,
       %{
         session: session(text: "<result>PASS</result>"),
         text: "<result>PASS</result>",
         events: []
       }}
    end

    agent_runner = Runner.runner(root, registry: registry, runtime_runner: runtime_runner)
    pipeline = %{name: "agent-bridge", steps: [%{id: "work", agent: "test.pass"}]}

    assert {:ok, result} = Run.run(root, pipeline, agent_runner)
    assert result.status == "completed"

    assert root |> Jsonl.ledger_path("agent_runs") |> Jsonl.read!() |> length() == 2
  end

  test "records agent failure when prerequisites are missing" do
    root = tmp_dir()

    registry =
      Registry.from_map(%{
        agents: %{
          "test.missing": %{
            description: "Missing prerequisite",
            required_paths: ["does-not-exist"],
            valid_results: ["PASS", "FAIL"],
            mode: "once"
          }
        }
      })

    runtime_runner = fn _root, _invocation, _opts -> flunk("runtime should not be invoked") end

    assert {:error, {:missing_required_paths, [_path]}} =
             Runner.run(root, "test.missing", %{},
               registry: registry,
               runtime_runner: runtime_runner
             )

    events = root |> Jsonl.ledger_path("agent_runs") |> Jsonl.read!()
    assert Enum.any?(events, &(&1["type"] == "agent.started"))
    assert Enum.any?(events, &(&1["type"] == "agent.failed"))
  end

  defp registry do
    Registry.from_map(%{
      defaults: %{
        description: "Configured test agent",
        required_paths: ["workspace"],
        valid_results: ["PASS", "FAIL"],
        mode: "once",
        runtime: %{adapter: "codex", mode: "cli_text"},
        result_mappings: %{
          PASS: %{status: "success", exit_code: 0, default_jump: "next"},
          FAIL: %{status: "failure", exit_code: 10, default_jump: "abort"}
        }
      },
      agents: %{
        "test.pass": %{}
      }
    })
  end

  defp session(attrs) when is_list(attrs), do: session(Map.new(attrs))

  defp session(attrs) do
    defaults = %{
      runtime: "codex",
      mode: "cli_text",
      status: "completed",
      started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }

    struct!(Session, Map.merge(defaults, attrs))
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "indexer-runner-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
