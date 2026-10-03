defmodule WebWidget.Protocol.EventsTest do
  use ExUnit.Case, async: true

  alias WebWidget.Protocol.Events

  @context %{user_id: "user_123", conversation_id: "conv_123"}
  @message %{id: "msg_123", content: "  Hello\nworld  "}

  test "init prepares only the bootstrap fields for a synchronous host request" do
    for prompt <- [nil, "", "Billing"],
        conversation <- [nil, "conv_123"] do
      context = %{
        user_id: "user_123",
        conversation_id: conversation,
        prompt_context: prompt,
        permissions: ["admin"],
        type: "response.error",
        mode: :async,
        widget_id: "spoofed"
      }

      assert Events.init("widget_support", context) ==
               {:ok,
                %{
                  type: "widget.init",
                  mode: :sync,
                  widget_id: "widget_support",
                  user_id: "user_123",
                  conversation_id: conversation,
                  prompt_context: prompt
                }}
    end

    assert {:ok, %{conversation_id: nil, prompt_context: nil}} =
             Events.init("widget_support", %{user_id: "user_123"})
  end

  test "create and edit retain message identity and text, whitelist fields and stamp each event" do
    context = Map.merge(@context, %{prompt_context: "private", permissions: ["admin"]})
    message = Map.merge(@message, %{role: "assistant", type: "response.message.create"})

    for {builder, type} <- [
          {&Events.create/3, "message.create"},
          {&Events.edit/3, "message.edit"}
        ] do
      before = DateTime.utc_now()
      assert {:ok, event} = builder.("widget_support", context, message)
      after_build = DateTime.utc_now()
      assert %DateTime{time_zone: "Etc/UTC"} = event.timestamp
      assert DateTime.compare(event.timestamp, before) in [:eq, :gt]
      assert DateTime.compare(event.timestamp, after_build) in [:eq, :lt]

      assert event == %{
               type: type,
               widget_id: "widget_support",
               mode: :async,
               user_id: "user_123",
               conversation_id: "conv_123",
               channel: "default",
               message: @message,
               timestamp: event.timestamp
             }
    end
  end

  test "both message types support an explicit public routing alias" do
    for builder <- [&Events.create/4, &Events.edit/4] do
      assert {:ok, %{channel: "support"}} =
               builder.("widget_support", @context, @message, "support")
    end
  end

  test "invalid init fields produce errors rather than malformed payloads" do
    assert {:error, :invalid_widget_id} = Events.init(" ", @context)
    assert {:error, :invalid_context} = Events.init("widget", nil)
    assert {:error, :invalid_context} = Events.init("widget", %{})

    for {field, value, reason} <- [
          {:user_id, nil, :invalid_user_id},
          {:user_id, " ", :invalid_user_id},
          {:conversation_id, 123, :invalid_conversation_id},
          {:conversation_id, "", :invalid_conversation_id},
          {:prompt_context, [], :invalid_prompt_context},
          {:prompt_context, %{}, :invalid_prompt_context},
          {:prompt_context, true, :invalid_prompt_context}
        ] do
      assert {:error, ^reason} = Events.init("widget", Map.put(@context, field, value))
    end
  end

  test "message events require initialized context, message identity, text and a channel" do
    for builder <- [&Events.create/4, &Events.edit/4] do
      assert {:error, :invalid_widget_id} = builder.(nil, @context, @message, "default")
      assert {:error, :invalid_channel} = builder.("widget", @context, @message, " ")

      for {field, value, reason} <- [
            {:user_id, "", :invalid_user_id},
            {:user_id, 123, :invalid_user_id},
            {:conversation_id, nil, :invalid_conversation_id},
            {:conversation_id, " ", :invalid_conversation_id}
          ] do
        assert {:error, ^reason} =
                 builder.("widget", Map.put(@context, field, value), @message, "default")
      end

      for {field, value, reason} <- [
            {:id, nil, :invalid_message_id},
            {:id, " ", :invalid_message_id},
            {:content, "\n ", :invalid_content},
            {:content, %{}, :invalid_content}
          ] do
        assert {:error, ^reason} =
                 builder.("widget", @context, Map.put(@message, field, value), "default")
      end

      for {context, message} <- [
            {nil, @message},
            {@context, nil},
            {@context, %{}},
            {%{}, @message}
          ] do
        assert {:error, :invalid_message_context} =
                 builder.("widget", context, message, "default")
      end
    end
  end
end
