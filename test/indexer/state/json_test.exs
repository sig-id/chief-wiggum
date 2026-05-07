defmodule Indexer.State.JsonTest do
  use ExUnit.Case, async: true

  alias Indexer.State.Json

  test "normalizes atom keys without converting booleans" do
    assert Json.normalize(%{enabled: true, disabled: false, value: nil, mode: :once}) == %{
             "enabled" => true,
             "disabled" => false,
             "value" => nil,
             "mode" => "once"
           }
  end
end
