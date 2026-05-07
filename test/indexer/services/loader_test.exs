defmodule Indexer.Services.LoaderTest do
  use ExUnit.Case, async: true

  alias Indexer.Services.Loader

  test "merges defaults, overrides, groups, and trigger shortcuts" do
    base = %{
      version: "2.0",
      defaults: %{timeout: 30, restart_policy: %{on_failure: "skip", max_retries: 1}},
      groups: %{"sync" => %{enabled: false}},
      services: [
        %{
          id: "later",
          phase: "post",
          order: 20,
          groups: ["sync"],
          schedule: %{type: "tick"},
          execution: %{
            type: "function",
            module: "Indexer.Services.Handlers.Control",
            function: "validate"
          }
        },
        %{
          id: "triggered",
          phase: "periodic",
          triggers: %{on_complete: ["later"], on_failure: ["missing"]},
          execution: %{
            type: "function",
            module: "Indexer.Services.Handlers.Control",
            function: "validate"
          }
        }
      ]
    }

    override = %{
      services: [
        %{id: "triggered", timeout: 60}
      ]
    }

    catalog = Loader.from_maps(base, override)

    assert {:ok, triggered} = Loader.get(catalog, "triggered")
    assert triggered["timeout"] == 60
    assert triggered["schedule"]["type"] == "event"

    assert triggered["schedule"]["trigger"] == [
             "service.succeeded:later",
             "service.failed:missing"
           ]

    assert {:ok, later} = Loader.get(catalog, "later")
    assert later["enabled"] == false
  end

  test "returns phase services in execution order and reverses shutdown" do
    catalog =
      Loader.from_maps(%{
        version: "2.0",
        services: [
          service("b", "shutdown", 10),
          service("a", "shutdown", 20),
          service("c", "post", 30),
          service("d", "post", 10)
        ]
      })

    assert Enum.map(Loader.phase_services(catalog, "post"), & &1["id"]) == ["d", "c"]
    assert Enum.map(Loader.phase_services(catalog, "shutdown"), & &1["id"]) == ["a", "b"]
  end

  defp service(id, phase, order) do
    %{
      id: id,
      phase: phase,
      order: order,
      schedule: %{type: "tick"},
      execution: %{
        type: "function",
        module: "Indexer.Services.Handlers.Control",
        function: "validate"
      }
    }
  end
end
