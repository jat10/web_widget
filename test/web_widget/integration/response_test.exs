defmodule WebWidget.Integration.ResponseTest do
  use ExUnit.Case, async: true
  alias WebWidget.Integration.Response

  test "history uses persisted IDs and positions, preserves real timestamps and strips private data" do
    response = %{
      type: :conversation_history,
      conversation_id: "chat",
      payload: %{
        messages: [
          %{
            message_id: 42,
            position: 8,
            role: "assistant",
            content: "Saved",
            provider_sent_at: ~U[2026-10-05 12:00:00Z],
            private_trace: "secret"
          },
          %{
            message_id: 43,
            position: 9,
            role: "user",
            content: "Untimestamped",
            provider_sent_at: nil
          }
        ]
      }
    }

    assert {:ok, encoded, [8, 9]} = Response.history(response, "12")

    assert encoded.payload.messages == [
             %{id: "42", role: "assistant", content: "Saved", timestamp: "2026-10-05T12:00:00Z"},
             %{id: "43", role: "user", content: "Untimestamped"}
           ]

    for messages <- [nil, [%{}], [nil], [%{message_id: 1, role: "system", content: "private"}]] do
      assert {:error, :invalid_history} =
               Response.history(%{response | payload: %{messages: messages}}, "12")
    end
  end

  test "semantic mapping rejects event mismatches and keeps public activity only" do
    response = %{
      type: :message_step,
      conversation_id: "chat",
      message_id: "transport",
      payload: %{
        kind: :activity,
        state: :running,
        step_id: "step",
        label: "Searching",
        private_trace: "private",
        tool_call: %{secret: true}
      }
    }

    assert {:ok, %{payload: payload}} = Response.encode("response.message.step", response, "12")

    assert payload == %{
             id: "step",
             message_id: "transport",
             kind: "status",
             state: "updated",
             label: "Searching",
             content: nil
           }

    assert {:error, :invalid_response} =
             Response.encode("response.message.complete", response, "12")

    assert {:error, :invalid_response} =
             Response.encode(
               "response.message.step",
               %{
                 response
                 | payload: %{
                     kind: :reasoning,
                     state: :running,
                     step_id: "step",
                     label: "private"
                   }
               },
               "12"
             )
  end

  test "protocol version and request correlation are mandatory" do
    refute Response.correlated?(%{protocol_version: 2, request_id: "r"}, "r")
    refute Response.correlated?(%{protocol_version: 1, request_id: "other"}, "r")
    assert Response.correlated?(%{protocol_version: 1, request_id: "r"}, "r")
  end
end
