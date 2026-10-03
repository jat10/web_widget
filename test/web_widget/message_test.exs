defmodule WebWidget.MessageTest do
  use ExUnit.Case, async: true

  alias WebWidget.Message

  test "creation serializes to the asynchronous callback contract" do
    message = %Message{
      widget_id: "widget_support",
      user_id: "user_123",
      conversation_id: "conv_123",
      timestamp: ~U[2026-10-02 10:00:00Z],
      message: %{id: "msg_456", content: "Hello"}
    }

    assert Message.to_map(message) == %{
             type: "message.create",
             widget_id: "widget_support",
             user_id: "user_123",
             conversation_id: "conv_123",
             timestamp: ~U[2026-10-02 10:00:00Z],
             message: %{id: "msg_456", content: "Hello"},
             mode: :async,
             channel: "default"
           }
  end

  test "editing preserves the message ID, updated content, mode and routing alias" do
    message = %Message{
      type: "message.edit",
      widget_id: "widget_support",
      user_id: "user_123",
      conversation_id: "conv_123",
      timestamp: ~U[2026-10-02 10:05:00Z],
      message: %{id: "msg_456", content: "Updated question"},
      mode: :sync,
      channel: "support"
    }

    assert Message.to_map(message) == %{
             type: "message.edit",
             widget_id: "widget_support",
             user_id: "user_123",
             conversation_id: "conv_123",
             timestamp: ~U[2026-10-02 10:05:00Z],
             message: %{id: "msg_456", content: "Updated question"},
             mode: :sync,
             channel: "support"
           }
  end
end
