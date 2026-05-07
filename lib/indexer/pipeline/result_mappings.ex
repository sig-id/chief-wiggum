defmodule Indexer.Pipeline.ResultMappings do
  @moduledoc """
  Gate result mapping resolution.

  The resolution order mirrors the spec: pipeline mappings, agent mappings, then
  global defaults. Agent-specific config loading is not wired yet, so callers can
  pass agent mappings explicitly when they have them.
  """

  @defaults %{
    "PASS" => %{"status" => "success", "exit_code" => 0, "default_jump" => "next"},
    "FAIL" => %{"status" => "failure", "exit_code" => 10, "default_jump" => "abort"},
    "FIX" => %{"status" => "partial", "exit_code" => 0, "default_jump" => "prev"},
    "SKIP" => %{"status" => "success", "exit_code" => 0, "default_jump" => "next"},
    "UNKNOWN" => %{"status" => "unknown", "exit_code" => 1, "default_jump" => "self"}
  }

  @doc """
  Resolves a gate result to status, exit code, and default jump.
  """
  @spec resolve(String.t(), map(), map()) :: {:ok, map()} | {:error, :unknown_result}
  def resolve(gate_result, pipeline_mappings \\ %{}, agent_mappings \\ %{}) do
    pipeline_mappings = Indexer.State.Json.normalize(pipeline_mappings || %{})
    agent_mappings = Indexer.State.Json.normalize(agent_mappings || %{})

    mapping =
      Map.get(pipeline_mappings, gate_result) ||
        Map.get(agent_mappings, gate_result) ||
        Map.get(@defaults, gate_result)

    if mapping do
      {:ok, mapping}
    else
      {:error, :unknown_result}
    end
  end

  @spec defaults() :: map()
  def defaults, do: @defaults
end
