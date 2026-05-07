defmodule Indexer.Agents.RegistryTest do
  use ExUnit.Case, async: true

  alias Indexer.Agents.Registry

  test "resolves config-only agents with defaults and overrides" do
    registry =
      Registry.from_map(%{
        defaults: %{
          description: "default description",
          required_paths: ["workspace"],
          valid_results: ["PASS", "FAIL"],
          mode: "once",
          runtime: %{adapter: "codex", mode: "cli_text"}
        },
        agents: %{
          "test.pass": %{
            valid_results: ["PASS", "SKIP"],
            runtime: %{adapter: "opencode"}
          }
        }
      })

    assert {:ok, resolved} =
             Registry.resolve(registry, "test.pass", %{
               "runtime" => %{"command" => ["printf", "PASS"]}
             })

    assert resolved.definition.type == "test.pass"
    assert resolved.definition.description == "default description"
    assert resolved.definition.valid_results == ["PASS", "SKIP"]
    assert resolved.runtime["adapter"] == "opencode"
    assert resolved.runtime["mode"] == "cli_text"
    assert resolved.runtime["command"] == ["printf", "PASS"]
  end

  test "loads markdown definitions when configured" do
    root = tmp_dir()
    path = Path.join(root, "agent.md")

    File.write!(path, """
    ---
    type: test.markdown
    description: Markdown agent
    required_paths: [workspace]
    valid_results: [PASS, FAIL]
    mode: once
    ---

    <INDEXER_SYSTEM_PROMPT>
    System {{step_id}}
    </INDEXER_SYSTEM_PROMPT>

    <INDEXER_USER_PROMPT>
    User {{step_id}}
    </INDEXER_USER_PROMPT>
    """)

    registry =
      Registry.from_map(
        %{
          defaults: %{
            description: "default description",
            required_paths: ["workspace"]
          },
          agents: %{
            "test.markdown": %{definition: "agent.md"}
          }
        },
        root
      )

    assert {:ok, resolved} = Registry.resolve(registry, "test.markdown")
    assert resolved.definition.description == "Markdown agent"
    assert resolved.markdown.system_prompt =~ "System"
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "indexer-registry-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
