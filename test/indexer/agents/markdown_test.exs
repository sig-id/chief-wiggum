defmodule Indexer.Agents.MarkdownTest do
  use ExUnit.Case, async: true

  alias Indexer.Agents.Markdown

  @agent """
  ---
  type: engineering.security-audit
  description: Audit the workspace
  required_paths: [workspace]
  valid_results: [PASS, FIX, FAIL]
  mode: ralph_loop
  readonly: true
  supervisor_interval: 2
  ---

  <INDEXER_SYSTEM_PROMPT>
  You audit {{workspace}}.
  <INDEXER_IF_SUPERVISOR>
  Feedback: {{supervisor_feedback}}
  </INDEXER_IF_SUPERVISOR>
  </INDEXER_SYSTEM_PROMPT>

  <INDEXER_USER_PROMPT>
  Work item {{work_item.id}}: {{work_item.title}}
  <INDEXER_IF_ITERATION_ZERO>
  Start fresh.
  </INDEXER_IF_ITERATION_ZERO>
  <INDEXER_IF_ITERATION_NONZERO>
  Continue.
  </INDEXER_IF_ITERATION_NONZERO>
  </INDEXER_USER_PROMPT>

  <INDEXER_CONTINUATION_PROMPT>
  Continue from {{parent.result}}.
  </INDEXER_CONTINUATION_PROMPT>
  """

  test "parses frontmatter and prompt sections" do
    parsed = Markdown.parse!(@agent)

    assert parsed.definition.type == "engineering.security-audit"
    assert parsed.definition.readonly == true
    assert parsed.definition.supervisor_interval == 2
    assert parsed.definition.valid_results == ["PASS", "FIX", "FAIL"]
    assert parsed.continuation_prompt =~ "Continue from"
  end

  test "renders variables and conditionals" do
    parsed = Markdown.parse!(@agent)

    system =
      Markdown.render(parsed, :system, %{
        workspace: "/tmp/work",
        supervisor_feedback: "tighten tests"
      })

    assert system =~ "You audit /tmp/work."
    assert system =~ "Feedback: tighten tests"

    user =
      Markdown.render(parsed, :user, %{
        iteration: 0,
        work_item: %{id: "TASK-001", title: "Add auth"}
      })

    assert user =~ "Work item TASK-001: Add auth"
    assert user =~ "Start fresh."
    refute user =~ "Continue."
  end
end
