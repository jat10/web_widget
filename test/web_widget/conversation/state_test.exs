defmodule WebWidget.Conversation.StateTest do
  use ExUnit.Case, async: true
  alias WebWidget.Conversation.State, as: Conversation

  test "request errors fail the pending assistant and active steps without regressing finished steps" do
    state =
      Conversation.new()
      |> Conversation.submit(%{id: "u", content: "hello"})
      |> Conversation.apply_event(%{
        type: "response.message.create",
        payload: %{id: "a", content: "Partial answer"}
      })

    state =
      Enum.reduce([{"active", "started"}, {"done", "completed"}], state, fn {id, status}, state ->
        Conversation.apply_event(state, %{
          type: "response.message.step",
          payload: %{
            id: id,
            message_id: "a",
            kind: "tool_call",
            state: status,
            label: "Search",
            content: nil
          }
        })
      end)

    state = Conversation.apply_event(state, %{type: "response.typing", payload: %{active: true}})
    assert state.typing

    error = %{
      type: "response.error",
      payload: %{request_type: "message.create", code: "failed", message: "Service unavailable"}
    }

    failed = Conversation.apply_event(state, error)
    assert failed.pending_reply == nil
    refute failed.typing
    assert failed.error == "Service unavailable"
    assert [user, assistant] = failed.messages
    assert user == hd(state.messages)
    assert assistant.status == "failed"
    assert assistant.error == "Service unavailable"
    assert assistant.content == "Partial answer"

    assert Enum.map(assistant.steps, &{&1.id, &1.state}) == [
             {"active", "failed"},
             {"done", "completed"}
           ]

    assert Conversation.apply_event(failed, error) == failed
  end

  test "additional assistant messages preserve the pending response owner" do
    create = %{type: "response.message.create", payload: %{id: "a", content: ""}}
    unsolicited = Conversation.apply_event(Conversation.new(), create)
    assert unsolicited.pending_reply == nil
    assert [%{id: "a", role: "assistant"}] = unsolicited.messages

    state =
      Conversation.new()
      |> Conversation.submit(%{id: "u", content: "hello"})
      |> Conversation.apply_event(create)
      |> Conversation.apply_event(%{create | payload: %{id: "b", content: "Another response"}})

    assert state.pending_reply == %{request_id: "u", id: "a"}
    assert Enum.map(state.messages, & &1.id) == ["u", "a", "b"]

    assert Conversation.apply_event(state, %{
             type: "response.conversation.history",
             payload: %{messages: []}
           }) == state

    assert Conversation.apply_event(state, %{type: "response.conversation.created"}) == state
  end

  test "streaming and completion retain the original message timestamp" do
    state =
      Conversation.new()
      |> Conversation.submit(%{id: "u", content: "hi", timestamp: "2026-10-03T10:00:00Z"})

    state =
      Conversation.apply_event(state, %{
        type: "response.message.create",
        payload: %{id: "a", content: "", timestamp: "2026-10-03T10:01:00Z"}
      })

    state =
      Conversation.apply_event(state, %{
        type: "response.message.edit",
        payload: %{id: "a", content: "Hello", timestamp: "2026-10-03T10:02:00Z"}
      })

    state =
      Conversation.apply_event(state, %{
        type: "response.message.complete",
        payload: %{id: "a", content: "Hello!", timestamp: "2026-10-03T10:03:00Z"}
      })

    assert Enum.map(state.messages, & &1.timestamp) == [
             "2026-10-03T10:00:00Z",
             "2026-10-03T10:01:00Z"
           ]
  end

  test "duplicates do not duplicate messages or steps and terminal state does not regress" do
    create = %{type: "response.message.create", payload: %{id: "a", content: ""}}

    step = %{
      type: "response.message.step",
      payload: %{
        id: "s",
        message_id: "a",
        kind: "tool_call",
        state: "started",
        label: "Search",
        content: nil
      }
    }

    state = Conversation.new() |> Conversation.submit(%{id: "u", content: "hello"})
    state = Enum.reduce([create, create, step, step], state, &Conversation.apply_event(&2, &1))
    assert length(state.messages) == 2
    assert length(List.last(state.messages).steps) == 1
    done = %{step | payload: %{step.payload | state: "completed", label: "Done"}}
    state = Conversation.apply_event(state, done)
    assert Conversation.apply_event(state, step) == state

    state =
      Conversation.apply_event(state, %{
        type: "response.message.complete",
        payload: %{id: "a", content: "Final"}
      })

    for event <- [
          create,
          step,
          %{type: "response.message.edit", payload: %{id: "a", content: "Late"}},
          %{
            type: "response.message.failed",
            payload: %{message_id: "a", code: "late", message: "Late failure"}
          }
        ] do
      assert Conversation.apply_event(state, event) == state
    end
  end

  test "unknown completions do not unlock a pending response and errors stop progress" do
    state = Conversation.new() |> Conversation.submit(%{id: "u", content: "hello"})

    assert Conversation.apply_event(state, %{
             type: "response.message.complete",
             payload: %{id: "unknown", content: "late"}
           }) == state

    state =
      Conversation.apply_event(state, %{
        type: "response.error",
        payload: %{request_type: "message.create", code: "failed", message: "Service unavailable"}
      })

    assert state.pending_reply == nil
    assert state.error == "Service unavailable"
  end
end
