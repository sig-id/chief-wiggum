defmodule Indexer.Services.SchedulerTest do
  use ExUnit.Case, async: true

  alias Indexer.Services.{Loader, Scheduler}

  test "runs a phase in dependency order" do
    root = tmp_dir()
    parent = self()

    catalog =
      Loader.from_maps(%{
        version: "2.0",
        services: [
          service("first", 10),
          service("second", 20, depends_on: ["first"])
        ]
      })

    function_runner = fn _execution, service, _context, _opts ->
      send(parent, {:ran, service["id"]})
      :ok
    end

    assert {:ok, results} =
             Scheduler.run_phase(root, catalog, "post", function_runner: function_runner)

    assert Enum.map(results, & &1["service_id"]) == ["first", "second"]
    assert_received {:ran, "first"}
    assert_received {:ran, "second"}
  end

  test "runs due periodic services only once for the same timestamp" do
    root = tmp_dir()
    parent = self()
    now = DateTime.utc_now()

    catalog =
      Loader.from_maps(%{
        version: "2.0",
        services: [
          Map.merge(service("interval", 10), %{
            phase: "periodic",
            schedule: %{type: "interval", interval: 60}
          })
        ]
      })

    function_runner = fn _execution, service, _context, _opts ->
      send(parent, {:ran, service["id"]})
      :ok
    end

    assert {:ok, [result]} =
             Scheduler.tick(root, catalog, function_runner: function_runner, now: now)

    assert result["service_id"] == "interval"
    assert_received {:ran, "interval"}

    assert {:ok, []} = Scheduler.tick(root, catalog, function_runner: function_runner, now: now)
  end

  test "runs event services whose triggers match" do
    root = tmp_dir()

    catalog =
      Loader.from_maps(%{
        version: "2.0",
        services: [
          %{
            id: "listener",
            phase: "periodic",
            schedule: %{type: "event", trigger: ["service.succeeded:*"]},
            execution: %{
              type: "function",
              module: "Indexer.Services.Handlers.Control",
              function: "validate"
            }
          }
        ]
      })

    assert {:ok, [result]} = Scheduler.trigger_event(root, catalog, "service.succeeded:anything")
    assert result["service_id"] == "listener"
  end

  defp service(id, order, extra \\ []) do
    %{
      id: id,
      phase: "post",
      order: order,
      schedule: %{type: "tick"},
      execution: %{
        type: "function",
        module: "Indexer.Services.Handlers.Control",
        function: "validate"
      }
    }
    |> Map.merge(Map.new(extra))
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "indexer-service-scheduler-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
