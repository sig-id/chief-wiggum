defmodule Indexer.AgentComm do
  @moduledoc """
  Query API for agent-to-agent communication over JSONL ledgers.

  This replaces v1's file-path resolver functions with deterministic projection
  reads. The ledger remains authoritative; callers can build disposable caches on
  top of these functions later.
  """

  alias Indexer.State.Jsonl

  @terminal_types MapSet.new(["agent.completed", "agent.failed"])

  @doc """
  Returns the latest terminal result for an agent type.

  Supported filters: `:worker_id`, `:work_item_id`, `:pipeline_run_id`, and
  `:node_run_id`.
  """
  @spec latest_result(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def latest_result(project_root, agent_type, opts \\ [])
      when is_binary(project_root) and is_binary(agent_type) do
    project_root
    |> terminal_agent_payloads()
    |> Enum.filter(&(&1["agent_type"] == agent_type))
    |> Enum.filter(&matches_filters?(&1, opts))
    |> List.last()
    |> case do
      nil -> {:error, :not_found}
      payload -> {:ok, result_projection(payload)}
    end
  end

  @doc """
  Returns the latest report output for an agent type.
  """
  @spec latest_report(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def latest_report(project_root, agent_type, opts \\ []) do
    with {:ok, result} <- latest_result(project_root, agent_type, opts),
         report when is_binary(report) and report != "" <- get_in(result, ["outputs", "report"]) do
      {:ok,
       %{
         "agent_run_id" => result["agent_run_id"],
         "agent_type" => result["agent_type"],
         "report" => report,
         "metadata" => Map.get(result, "metadata", %{})
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns all terminal agent results in ledger order.
  """
  @spec results(Path.t(), keyword()) :: [map()]
  def results(project_root, opts \\ []) when is_binary(project_root) do
    project_root
    |> terminal_agent_payloads()
    |> Enum.filter(&matches_filters?(&1, opts))
    |> Enum.map(&result_projection/1)
  end

  defp terminal_agent_payloads(project_root) do
    project_root
    |> Jsonl.ledger_path("agent_runs")
    |> Jsonl.read!()
    |> Enum.filter(&(MapSet.member?(@terminal_types, &1["type"]) and is_map(&1["payload"])))
    |> Enum.map(& &1["payload"])
  end

  defp result_projection(payload) do
    %{
      "agent_run_id" => payload["agent_run_id"],
      "agent_type" => payload["agent_type"],
      "worker_id" => payload["worker_id"],
      "work_item_id" => payload["work_item_id"],
      "pipeline_run_id" => payload["pipeline_run_id"],
      "node_run_id" => payload["node_run_id"],
      "step_id" => payload["step_id"],
      "status" => payload["status"],
      "exit_code" => payload["exit_code"],
      "outputs" => Map.get(payload, "outputs", %{}),
      "artifacts" => Map.get(payload, "artifacts", []),
      "effects" => Map.get(payload, "effects", []),
      "errors" => Map.get(payload, "errors", []),
      "metadata" => Map.get(payload, "metadata", %{}),
      "completed_at" => payload["completed_at"]
    }
  end

  defp matches_filters?(payload, opts) do
    Enum.all?(opts, fn {key, value} ->
      filter_key = Atom.to_string(key)
      is_nil(value) or Map.get(payload, filter_key) == value
    end)
  end
end
