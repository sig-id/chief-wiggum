defmodule Indexer.Services.Daemon do
  @moduledoc """
  OTP service daemon.

  The daemon is intentionally thin: it owns timers and lifecycle phases, while
  `Indexer.Services.Scheduler` owns deterministic scheduling decisions.
  """

  use GenServer

  alias Indexer.Services.{Loader, Scheduler}

  @type option ::
          {:project_root, Path.t()}
          | {:catalog, Loader.Catalog.t()}
          | {:tick_interval_ms, non_neg_integer()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    catalog = Keyword.get_lazy(opts, :catalog, fn -> Loader.load!(project_root) end)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, 60_000)

    state = %{
      project_root: project_root,
      catalog: catalog,
      tick_interval_ms: tick_interval_ms,
      scheduler_opts: Keyword.get(opts, :scheduler_opts, [])
    }

    Scheduler.run_phase(project_root, catalog, "startup", state.scheduler_opts)
    schedule_tick(tick_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Scheduler.tick(state.project_root, state.catalog, state.scheduler_opts)
    schedule_tick(state.tick_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Scheduler.run_phase(state.project_root, state.catalog, "shutdown", state.scheduler_opts)
    :ok
  end

  defp schedule_tick(interval_ms) when interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end
end
