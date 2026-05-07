defmodule Indexer.Services.Scheduler do
  @moduledoc """
  Phase and tick scheduler for service catalogs.
  """

  alias Indexer.Services.{Loader, Runner, State}

  @max_event_depth 4

  @doc """
  Runs one phase sequentially.
  """
  @spec run_phase(Path.t(), Loader.Catalog.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def run_phase(project_root, %Loader.Catalog{} = catalog, phase, opts \\ [])
      when is_binary(project_root) and is_binary(phase) do
    services = Loader.phase_services(catalog, phase)
    run_services(project_root, services, opts)
  end

  @doc """
  Runs one scheduler tick: pre phase, due periodic services, post phase.
  """
  @spec tick(Path.t(), Loader.Catalog.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def tick(project_root, %Loader.Catalog{} = catalog, opts \\ []) do
    with {:ok, pre} <- run_phase(project_root, catalog, "pre", opts),
         {:ok, periodic} <- run_due_periodic(project_root, catalog, opts),
         {:ok, post} <- run_phase(project_root, catalog, "post", opts) do
      {:ok, pre ++ periodic ++ post}
    end
  end

  @doc """
  Runs enabled event-scheduled services matching an event name.
  """
  @spec trigger_event(Path.t(), Loader.Catalog.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def trigger_event(project_root, %Loader.Catalog{} = catalog, event, opts \\ [])
      when is_binary(project_root) and is_binary(event) do
    depth = Keyword.get(opts, :event_depth, 0)

    if depth >= @max_event_depth do
      {:ok, []}
    else
      services =
        catalog
        |> Loader.phase_services("periodic")
        |> Enum.filter(&(get_in(&1, ["schedule", "type"]) == "event"))
        |> Enum.filter(&event_matches?(&1, event))

      run_services(project_root, services, opts)
    end
  end

  defp run_due_periodic(project_root, catalog, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    state = State.current(project_root)

    services =
      catalog
      |> Loader.phase_services("periodic")
      |> Enum.reject(&(get_in(&1, ["schedule", "type"]) == "event"))
      |> Enum.filter(&due?(&1, state, now))
      |> Enum.reject(&circuit_open?(&1, state, now))

    run_services(project_root, services, opts)
  end

  defp run_services(project_root, services, opts) do
    Enum.reduce_while(services, {:ok, [], MapSet.new()}, fn service, {:ok, results, succeeded} ->
      deps = service |> Map.get("depends_on", []) |> List.wrap()

      if Enum.all?(deps, &MapSet.member?(succeeded, &1)) do
        case Runner.run(project_root, service, opts) do
          {:ok, result} ->
            succeeded =
              if result["status"] in ["success", "skipped", "queued"],
                do: MapSet.put(succeeded, service["id"]),
                else: succeeded

            {:cont, {:ok, results ++ [result], succeeded}}

          {:error, result} when is_map(result) ->
            if Map.get(service, "required", false) do
              {:halt, {:error, {:required_service_failed, service["id"], result}}}
            else
              {:cont, {:ok, results ++ [result], succeeded}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, results ++ [dependency_skip(project_root, service, deps)], succeeded}}
      end
    end)
    |> case do
      {:ok, results, _succeeded} -> {:ok, results}
      other -> other
    end
  end

  defp dependency_skip(project_root, service, deps) do
    Runner.run(
      project_root,
      Map.put(service, "condition", %{"service_mode" => "__dependency_skip__"}),
      run_mode: "default"
    )
    |> case do
      {:ok, result} -> Map.put(result, "missing_dependencies", deps)
      {:error, result} when is_map(result) -> result
    end
  end

  defp due?(service, state, now) do
    schedule = Map.get(service, "schedule", %{})

    case Map.get(schedule, "type") do
      "tick" ->
        true

      "interval" ->
        interval = Map.get(schedule, "interval", 0)
        entry = Map.get(state, service["id"], %{})

        cond do
          interval <= 0 ->
            false

          Map.get(schedule, "run_on_startup", false) and is_nil(entry["last_run"]) ->
            true

          is_nil(entry["last_run"]) ->
            true

          true ->
            elapsed_seconds(entry["last_run"], now) >= interval + Map.get(schedule, "jitter", 0)
        end

      "continuous" ->
        entry = Map.get(state, service["id"], %{})
        delay = Map.get(schedule, "restart_delay", 5)
        is_nil(entry["last_run"]) or elapsed_seconds(entry["last_run"], now) >= delay

      "cron" ->
        Map.get(schedule, "run_on_startup", false) and
          is_nil(get_in(state, [service["id"], "last_run"]))

      _ ->
        false
    end
  end

  defp circuit_open?(service, state, now) do
    entry = Map.get(state, service["id"], %{})
    breaker = Map.get(service, "circuit_breaker", %{})

    if Map.get(breaker, "enabled", false) and entry["circuit_state"] == "open" do
      elapsed_seconds(entry["circuit_opened_at"], now) < Map.get(breaker, "cooldown", 300)
    else
      false
    end
  end

  defp event_matches?(service, event) do
    service
    |> get_in(["schedule", "trigger"])
    |> List.wrap()
    |> Enum.any?(&trigger_matches?(&1, event))
  end

  defp trigger_matches?(pattern, event) when is_binary(pattern) do
    pattern == event or
      (String.ends_with?(pattern, "*") and
         String.starts_with?(event, String.trim_trailing(pattern, "*")))
  end

  defp trigger_matches?(_pattern, _event), do: false

  defp elapsed_seconds(nil, _now), do: 9_999_999_999

  defp elapsed_seconds(timestamp, now) when is_binary(timestamp) do
    with {:ok, then_dt, _} <- DateTime.from_iso8601(timestamp) do
      DateTime.diff(now, then_dt, :second)
    else
      _ -> 0
    end
  end
end
