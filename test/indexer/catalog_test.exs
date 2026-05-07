defmodule Indexer.CatalogTest do
  use ExUnit.Case, async: true

  alias Indexer.Agents.Registry
  alias Indexer.Pipeline.Schema

  @repo_root Path.expand("../..", __DIR__)

  test "built-in agent catalog resolves copied markdown and deterministic v1 agents" do
    registry = Registry.from_file!(Path.join(@repo_root, "config/agents.json"))

    assert map_size(registry.agents) >= 40

    Enum.each(registry.agents, fn {agent_type, _config} ->
      assert {:ok, resolved} = Registry.resolve(registry, agent_type)
      assert resolved.definition.type == agent_type

      if resolved.markdown do
        assert resolved.markdown.system_prompt != ""
        assert resolved.markdown.user_prompt != ""
      end
    end)
  end

  test "built-in pipelines validate and reference registered agents" do
    registry = Registry.from_file!(Path.join(@repo_root, "config/agents.json"))
    registered_agents = registry.agents |> Map.keys() |> MapSet.new()

    @repo_root
    |> Path.join("config/pipelines/*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      pipeline = Indexer.Config.read_json!(path)

      assert_valid_pipeline!(path, pipeline)

      referenced_agents = pipeline |> collect_agents() |> MapSet.new()

      missing_agents =
        referenced_agents |> MapSet.difference(registered_agents) |> MapSet.to_list()

      assert missing_agents == []
    end)
  end

  defp assert_valid_pipeline!(path, pipeline) do
    case Schema.validate(pipeline) do
      :ok ->
        :ok

      {:error, errors} ->
        flunk("""
        Invalid pipeline #{Path.relative_to(path, @repo_root)}:
        #{Enum.map_join(errors, "\n", &"#{&1.path}: #{&1.message}")}
        """)
    end
  end

  defp collect_agents(%{"steps" => steps}) when is_list(steps) do
    Enum.flat_map(steps, &collect_step_agents/1)
  end

  defp collect_agents(_pipeline), do: []

  defp collect_step_agents(%{} = step) do
    [Map.get(step, "agent") | collect_handler_agents(Map.get(step, "on_result", %{}))]
    |> Enum.filter(&is_binary/1)
  end

  defp collect_step_agents(_step), do: []

  defp collect_handler_agents(handlers) when is_map(handlers) do
    handlers
    |> Map.values()
    |> Enum.flat_map(fn
      %{"agent" => _agent} = handler -> collect_step_agents(handler)
      _handler -> []
    end)
  end

  defp collect_handler_agents(_handlers), do: []
end
