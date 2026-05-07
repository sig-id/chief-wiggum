defmodule Indexer.Services.Loader do
  @moduledoc """
  Loads and normalizes service configuration.

  This preserves the v1 service loader shape: defaults are merged into every
  service, project overrides merge by service id, trigger shortcuts become event
  schedules, groups can disable services, and phase lookups are sorted by order.
  """

  alias Indexer.Services.Schema

  defmodule Catalog do
    @moduledoc false

    @enforce_keys [:version, :services]
    defstruct version: "2.0", defaults: %{}, groups: %{}, services: [], by_id: %{}

    @type t :: %__MODULE__{}
  end

  @phase_order %{
    "startup" => 0,
    "pre" => 1,
    "periodic" => 2,
    "post" => 3,
    "shutdown" => 4
  }

  @doc """
  Loads built-in config and optional project override from `.indexer/services.json`.
  """
  @spec load!(Path.t(), keyword()) :: %Catalog{}
  def load!(project_root, opts \\ []) when is_binary(project_root) do
    config_path =
      Keyword.get(opts, :config_path, Path.expand("config/services.json", File.cwd!()))

    override_path =
      Keyword.get(
        opts,
        :override_path,
        Path.join(Indexer.state_dir(project_root), "services.json")
      )

    base = Indexer.Config.read_json!(config_path)

    override =
      if File.exists?(override_path) do
        Indexer.Config.read_json!(override_path)
      else
        %{}
      end

    from_maps(base, override)
  end

  @doc """
  Builds a catalog from base config plus an optional override map.
  """
  @spec from_maps(map(), map()) :: %Catalog{}
  def from_maps(base, override \\ %{}) when is_map(base) and is_map(override) do
    base = Indexer.State.Json.normalize(base)
    override = Indexer.State.Json.normalize(override)

    merged =
      base
      |> merge_root_override(override)
      |> apply_defaults()
      |> normalize_triggers()
      |> apply_group_enablement()
      |> sort_services()

    Schema.validate!(merged)

    services = Map.fetch!(merged, "services")

    %Catalog{
      version: Map.fetch!(merged, "version"),
      defaults: Map.get(merged, "defaults", %{}),
      groups: Map.get(merged, "groups", %{}),
      services: services,
      by_id: Map.new(services, &{&1["id"], &1})
    }
  end

  @doc """
  Returns enabled services for a phase, sorted by order.
  """
  @spec phase_services(%Catalog{}, String.t()) :: [map()]
  def phase_services(%Catalog{} = catalog, phase) when is_binary(phase) do
    catalog.services
    |> Enum.filter(&(&1["phase"] == phase and Map.get(&1, "enabled", true)))
    |> sort_phase(phase)
  end

  @spec get(%Catalog{}, String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(%Catalog{} = catalog, service_id) when is_binary(service_id) do
    case Map.fetch(catalog.by_id, service_id) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :not_found}
    end
  end

  defp merge_root_override(base, override) do
    base
    |> Indexer.Agents.Registry.deep_merge(Map.take(override, ["defaults", "groups", "version"]))
    |> merge_service_overrides(Map.get(override, "services", []))
  end

  defp merge_service_overrides(base, overrides) when is_list(overrides) do
    services = Map.get(base, "services", [])
    by_id = Map.new(services, &{&1["id"], &1})

    merged_by_id =
      Enum.reduce(overrides, by_id, fn override, acc ->
        case Map.get(override, "id") do
          nil ->
            acc

          id ->
            Map.update(acc, id, override, &Indexer.Agents.Registry.deep_merge(&1, override))
        end
      end)

    ordered =
      services
      |> Enum.map(&Map.fetch!(merged_by_id, &1["id"]))
      |> Kernel.++(Enum.reject(overrides, &Map.has_key?(by_id, &1["id"])))

    Map.put(base, "services", ordered)
  end

  defp merge_service_overrides(base, _overrides), do: base

  defp apply_defaults(config) do
    defaults = Map.get(config, "defaults", %{})

    services =
      config
      |> Map.get("services", [])
      |> Enum.map(fn service ->
        defaults
        |> Indexer.Agents.Registry.deep_merge(service)
        |> Map.put_new("phase", "periodic")
        |> Map.put_new("order", 50)
        |> Map.put_new("enabled", true)
        |> Map.put_new("required", false)
        |> Map.put_new("groups", [])
        |> Map.put_new("depends_on", [])
        |> Map.put_new("concurrency", %{"max_instances" => 1, "if_running" => "skip"})
      end)

    Map.put(config, "services", services)
  end

  defp normalize_triggers(config) do
    services =
      config
      |> Map.get("services", [])
      |> Enum.map(fn service ->
        case Map.get(service, "triggers") do
          nil ->
            service

          triggers ->
            trigger_list =
              []
              |> add_trigger_kind(triggers, "on_complete", "service.succeeded")
              |> add_trigger_kind(triggers, "on_failure", "service.failed")
              |> add_trigger_kind(triggers, "on_finish", "service.completed")

            service
            |> Map.delete("triggers")
            |> Map.put("schedule", %{"type" => "event", "trigger" => trigger_list})
        end
      end)

    Map.put(config, "services", services)
  end

  defp add_trigger_kind(acc, triggers, key, prefix) do
    acc ++
      (triggers
       |> Map.get(key, [])
       |> List.wrap()
       |> Enum.map(&"#{prefix}:#{&1}"))
  end

  defp apply_group_enablement(config) do
    groups = Map.get(config, "groups", %{})

    services =
      config
      |> Map.get("services", [])
      |> Enum.map(fn service ->
        enabled? =
          service
          |> Map.get("groups", [])
          |> List.wrap()
          |> Enum.all?(&(get_in(groups, [&1, "enabled"]) != false))

        if enabled?, do: service, else: Map.put(service, "enabled", false)
      end)

    Map.put(config, "services", services)
  end

  defp sort_services(config) do
    services =
      config
      |> Map.get("services", [])
      |> Enum.sort_by(fn service ->
        {Map.get(@phase_order, service["phase"], 99), Map.get(service, "order", 50),
         service["id"]}
      end)

    Map.put(config, "services", services)
  end

  defp sort_phase(services, "shutdown") do
    Enum.sort_by(services, &{Map.get(&1, "order", 50), &1["id"]}, :desc)
  end

  defp sort_phase(services, _phase) do
    Enum.sort_by(services, &{Map.get(&1, "order", 50), &1["id"]})
  end
end
