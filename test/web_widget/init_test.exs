defmodule WebWidget.InitTest do
  use ExUnit.Case, async: true

  alias WebWidget.Init

  test "initialization serializes to the synchronous callback contract" do
    init = %Init{widget_id: "widget_support", user_id: "user_123"}

    assert Init.to_map(init) == %{
             type: "widget.init",
             widget_id: "widget_support",
             user_id: "user_123",
             conversation_id: nil,
             prompt_context: nil,
             mode: :sync
           }
  end

  test "resuming preserves the conversation, mode and supported prompt contexts" do
    for context <- [nil, "", "Billing page"] do
      init = %Init{
        widget_id: "widget_support",
        user_id: "user_123",
        conversation_id: "conv_123",
        prompt_context: context,
        mode: :async
      }

      assert %{
               type: "widget.init",
               conversation_id: "conv_123",
               prompt_context: ^context,
               mode: :async
             } = Init.to_map(init)
    end
  end
end
