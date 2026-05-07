defmodule Indexer.Runtime.ExecutableTest do
  use ExUnit.Case, async: true

  alias Indexer.Runtime
  alias Indexer.Runtime.Invocation
  alias Indexer.State.Jsonl

  test "invokes an executable adapter and records normalized runtime events" do
    root = tmp_dir()

    stdout =
      JSON.encode!(%{
        text: "<result>PASS</result>",
        session_id: "session-1",
        turn_id: "turn-1",
        events: [
          %{event_type: "message.completed", payload: %{text: "done"}}
        ]
      })

    invocation =
      invocation(%{
        runtime_config: %{"command" => ["printf", "%s", stdout], "timeout_seconds" => 5}
      })

    assert {:ok, result} = Runtime.invoke(root, invocation)
    assert result.text == "<result>PASS</result>"
    assert result.session.runtime_session_id == "session-1"
    assert [_event] = result.events

    events = root |> Jsonl.ledger_path("agent_events") |> Jsonl.read!()
    assert Enum.any?(events, &(&1["type"] == "runtime.invocation.started"))
    assert Enum.any?(events, &(&1["type"] == "agent.runtime_event"))
    assert Enum.any?(events, &(&1["type"] == "runtime.invocation.completed"))
  end

  defp invocation(overrides) do
    defaults = %{
      agent_run_id: "agent-run-1",
      agent_type: "test.pass",
      runtime: "codex",
      mode: "cli_text",
      workspace_path: File.cwd!(),
      objective: %{"system" => "system", "user" => "user"},
      policy: %{"timeout_seconds" => 5, "max_turns" => 1},
      runtime_config: %{},
      context: %{"pipeline_run_id" => "pipeline-run-1"},
      artifacts: []
    }

    struct!(Invocation, Map.merge(defaults, overrides))
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "indexer-runtime-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
