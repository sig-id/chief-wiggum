defmodule Indexer.Hooks.ExecutorTest do
  use ExUnit.Case, async: true

  alias Indexer.Hooks.Executor

  defmodule SampleHook do
    @behaviour Indexer.Hooks.Hook

    @impl true
    def run(envelope) do
      %{
        status: "ok",
        context: %{prepared: envelope["work_item"]["id"]},
        diagnostics: ["prepared"]
      }
    end
  end

  test "runs module hooks and normalizes output" do
    assert {:ok, result} =
             Executor.run(
               %{"kind" => "module", "module" => "Indexer.Hooks.ExecutorTest.SampleHook"},
               %{"work_item" => %{"id" => "TASK-001"}}
             )

    assert result["status"] == "ok"
    assert result["context"]["prepared"] == "TASK-001"
    assert result["artifacts"] == []
  end

  test "runs executable hooks with JSON stdin/stdout" do
    elixir = System.find_executable("elixir")

    script =
      "input = IO.read(:stdio, :eof) |> JSON.decode!(); IO.write(JSON.encode!(%{context: %{agent: input[\"agent_id\"]}}))"

    assert {:ok, result} =
             Executor.run(
               %{"kind" => "executable", "command" => [elixir, "-e", script]},
               %{"agent_id" => "engineering.test"}
             )

    assert result["context"]["agent"] == "engineering.test"
  end

  test "returns hard_fail for invalid executable output" do
    elixir = System.find_executable("elixir")

    assert {:error, result} =
             Executor.run(
               %{"kind" => "executable", "command" => [elixir, "-e", "IO.write(\"not json\")"]},
               %{}
             )

    assert result["status"] == "hard_fail"
  end
end
