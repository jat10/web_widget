defmodule WebWidget.Integration.UserMessagesTest do
  use ExUnit.Case, async: true
  alias WebWidget.Conversation.State
  alias WebWidget.Integration.{Response, UserMessages}

  defp chat(messages \\ []) do
    %{
      state: %{State.new() | messages: messages},
      message_positions: %{},
      user_requests: %{},
      streams: %{},
      persisted_refs: %{}
    }
  end

  defp row(id, position, content),
    do: %{id: id, role: "user", content: content, position: position}

  test "canonical IDs and positions converge receipt, live and history without duplicate rows" do
    message = row("saved-user", 3, "Saved text")
    assert {:ok, state} = UserMessages.merge(chat(), message, "request")
    assert {:ok, duplicate} = UserMessages.merge(state, message, "request")
    assert duplicate == state
    assert {:ok, replayed} = UserMessages.merge(state, message, "replay-request")
    assert length(replayed.state.messages) == 1

    history = %{
      chat([Map.merge(message, %{status: "complete", steps: [], error: nil})])
      | message_positions: %{"saved-user" => 3}
    }

    assert {:ok, restored} = UserMessages.merge(history, message, "request")
    assert length(restored.state.messages) == 1
  end

  test "canonical ordering inserts late user records before their fast assistant" do
    assistant = %{id: "assistant", role: "assistant", content: "Fast answer", status: "complete"}

    state = %{
      chat([assistant])
      | streams: %{"assistant" => %{request_id: "request", status: :terminal}},
        persisted_refs: %{"assistant" => %{user_message_id: "user-1"}}
    }

    assert {:ok, state} = UserMessages.merge(state, row("user-2", 2, "Second"), "other-request")
    assert {:ok, state} = UserMessages.merge(state, row("user-1", 1, "First"), "request")
    assert Enum.map(state.state.messages, & &1.id) == ["user-1", "assistant", "user-2"]
  end

  test "conflicting identities, positions and assistant namespace collisions fail closed" do
    assert {:ok, state} = UserMessages.merge(chat(), row("saved", 1, "Original"), "request")
    assert {:error, _} = UserMessages.merge(state, row("different", 2, "Different"), "request")
    assert {:error, _} = UserMessages.merge(state, row("saved", 1, "Changed"), "request")
    assert {:error, _} = UserMessages.merge(state, row("other", 1, "Conflict"), "other-request")

    assert {:error, _} =
             UserMessages.merge(
               chat([%{id: "saved", role: "assistant", content: "Answer"}]),
               row("saved", 1, "Input"),
               "request"
             )
  end

  test "saved-user validation requires authoritative shape and never invents timestamps" do
    response = %{
      protocol_version: 2,
      type: :user_message,
      request_id: "request",
      conversation_id: "selected",
      message_id: nil,
      payload: %{
        accepted: true,
        created: false,
        user_message: %{
          message_id: "saved",
          position: 1,
          role: "user",
          content: "Saved",
          provider_sent_at: nil
        }
      }
    }

    assert {:ok, row} = Response.saved_user(response, "42")
    refute Map.has_key?(row, :timestamp)

    for invalid <- [
          put_in(response.payload.accepted, false),
          %{response | message_id: "assistant"},
          put_in(response.payload.user_message.role, "external"),
          put_in(response.payload.user_message.position, 0),
          put_in(response.payload.user_message.content, <<255>>)
        ] do
      assert {:error, :invalid_user_message} = Response.saved_user(invalid, "42")
    end
  end
end
