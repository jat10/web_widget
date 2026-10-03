defmodule WebWidget.Protocol.ResponseTest do
  use ExUnit.Case, async: true
  alias WebWidget.Protocol.Response

  defp event(type, payload),
    do: %{type: type, widget_id: "widget", conversation_id: "conversation", payload: payload}

  test "step validation rejects malformed states and strips arbitrary metadata" do
    step = %{
      id: "s",
      message_id: "a",
      kind: "tool_call",
      state: "started",
      label: "Search",
      content: "<script>untrusted</script>",
      metadata: %{token: "secret"}
    }

    assert {:ok, %{payload: safe}} = Response.normalize(event("response.message.step", step))
    refute Map.has_key?(safe, :metadata)
    assert safe.content == step.content

    for invalid <- [
          %{step | state: "running"},
          %{step | kind: "unknown"},
          %{step | id: " "},
          %{step | content: %{}},
          %{step | metadata: []}
        ] do
      assert {:error, :invalid_response} =
               Response.normalize(event("response.message.step", invalid))
    end
  end

  test "history rejects duplicate IDs and malformed entries" do
    message = %{id: "m", role: "assistant", content: "History"}

    assert {:ok, _} =
             Response.normalize(event("response.conversation.history", %{messages: [message]}))

    for messages <- [
          [message, message],
          [nil],
          [%{message | role: "admin"}],
          [%{message | content: nil}]
        ] do
      assert {:error, :invalid_response} =
               Response.normalize(event("response.conversation.history", %{messages: messages}))
    end
  end

  test "normalizes timestamp offsets and validates nested conversation histories" do
    message = %{id: "m", role: "user", content: "Hello", timestamp: "2026-10-03T12:30:00+03:00"}
    conversation = %{id: "c", title: "Chat", messages: [message]}

    response =
      event("response.conversation.history", %{messages: [message], conversations: [conversation]})

    assert {:ok, normalized} = Response.normalize(response)
    assert hd(normalized.payload.messages).timestamp == "2026-10-03T09:30:00Z"
    assert hd(hd(normalized.payload.conversations).messages).timestamp == "2026-10-03T09:30:00Z"

    for conversations <- [
          [conversation, conversation],
          [%{conversation | title: " "}],
          [%{conversation | messages: [%{message | timestamp: "yesterday"}]}],
          "invalid"
        ] do
      assert {:error, :invalid_response} =
               Response.normalize(put_in(response, [:payload, :conversations], conversations))
    end
  end

  test "initialization requires host identity and routing fields" do
    response = %{
      type: "response.widget.initialized",
      widget_id: "widget",
      conversation_id: "conversation",
      user_id: "accepted-user"
    }

    assert {:ok, ^response} = Response.normalize(response)

    for field <- [:widget_id, :conversation_id, :user_id] do
      assert {:error, :invalid_response} = Response.normalize(Map.put(response, field, " "))
    end
  end
end
