defmodule Indexer.Agents.Registry do
  @moduledoc """
  Agent registry and config resolution.

  Registry entries are intentionally compatible with the v1 shape: stable agent
  type keys plus per-agent overrides. Markdown definitions may be referenced by
  `definition`, but config-only agents are also supported so site-local agents can
  be introduced before their prompt files exist.
  """

  alias Indexer.Agents.{Definition, Markdown}

  defmodule Resolved do
    @moduledoc false

    @enforce_keys [:type, :definition, :config]
    defstruct [
      :type,
      :definition,
      :markdown,
      config: %{},
      result_mappings: %{},
      runtime: %{},
      max_iterations: nil,
      max_turns: nil,
      timeout_seconds: nil
    ]
  end

  defstruct defaults: %{}, agents: %{}, base_dir: File.cwd!()

  @type t :: %__MODULE__{}
  @type resolved :: %Resolved{}

  @doc """
  Loads a registry from a JSON config file.
  """
  @spec from_file!(Path.t()) :: t()
  def from_file!(path) when is_binary(path) do
    path
    |> Indexer.Config.read_json!()
    |> from_map(Path.dirname(path))
  end

  @doc """
  Builds a registry from a decoded config map.
  """
  @spec from_map(map(), Path.t()) :: t()
  def from_map(map, base_dir \\ File.cwd!()) when is_map(map) and is_binary(base_dir) do
    normalized = Indexer.State.Json.normalize(map)

    %__MODULE__{
      defaults: Map.get(normalized, "defaults", %{}),
      agents: Map.get(normalized, "agents", %{}),
      base_dir: base_dir
    }
  end

  @doc """
  Resolves an agent type with optional step/operator overrides.
  """
  @spec resolve(t(), String.t(), map()) :: {:ok, resolved()} | {:error, term()}
  def resolve(%__MODULE__{} = registry, agent_type, overrides \\ %{})
      when is_binary(agent_type) do
    agent_config = Map.get(registry.agents, agent_type, %{})
    config = registry.defaults |> deep_merge(agent_config) |> deep_merge(overrides)

    with {:ok, markdown, base_definition} <- load_base_definition(registry, agent_type, config),
         {:ok, definition} <-
           merge_definition(
             agent_type,
             base_definition,
             registry.defaults,
             agent_config,
             overrides
           ) do
      runtime =
        registry.defaults
        |> Map.get("runtime", %{})
        |> deep_merge(Map.get(base_definition, "runtime", %{}))
        |> deep_merge(Map.get(agent_config, "runtime", %{}))
        |> deep_merge(Map.get(overrides, "runtime", %{}))

      {:ok,
       %Resolved{
         type: agent_type,
         definition: definition,
         markdown: markdown,
         config: config,
         runtime: runtime,
         result_mappings: Map.get(config, "result_mappings", %{}),
         max_iterations: Map.get(config, "max_iterations"),
         max_turns: Map.get(config, "max_turns"),
         timeout_seconds: Map.get(config, "timeout_seconds")
       }}
    end
  end

  @doc """
  Recursively merges two JSON-style maps.
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, old, new ->
      if is_map(old) and is_map(new), do: deep_merge(old, new), else: new
    end)
  end

  defp load_base_definition(registry, _agent_type, config) do
    case Map.get(config, "definition") do
      nil ->
        {:ok, nil, %{}}

      path when is_binary(path) ->
        markdown = Markdown.parse_file!(resolve_path(registry.base_dir, path))

        {:ok, markdown,
         markdown.definition |> Map.from_struct() |> Indexer.State.Json.normalize()}

      other ->
        {:error, {:invalid_definition_path, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  end

  defp merge_definition(agent_type, base_definition, defaults, agent_config, overrides) do
    definition_overrides =
      agent_config
      |> deep_merge(overrides)
      |> Map.take(definition_keys())

    definition_config =
      base_definition
      |> Map.drop(["__struct__"])
      |> deep_merge(definition_overrides)
      |> Map.put("type", agent_type)
      |> Map.put_new(
        "description",
        Map.get(defaults, "description", "Configured Indexer agent #{agent_type}")
      )
      |> Map.put_new("required_paths", Map.get(defaults, "required_paths", ["workspace"]))
      |> Map.put_new("valid_results", Map.get(defaults, "valid_results", ["PASS", "FAIL"]))
      |> Map.put_new("mode", Map.get(defaults, "mode", "once"))

    Definition.from_map(definition_config)
  end

  defp definition_keys do
    [
      "description",
      "required_paths",
      "valid_results",
      "mode",
      "readonly",
      "report_tag",
      "result_tag",
      "output_path",
      "completion_check",
      "session_from",
      "supervisor_interval",
      "plan_file",
      "outputs",
      "runtime",
      "hooks",
      "capabilities",
      "artifact_contracts"
    ]
  end

  defp resolve_path(base_dir, path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, base_dir)
    end
  end
end
