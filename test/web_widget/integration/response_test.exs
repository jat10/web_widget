defmodule WebWidget.Integration.ResponseTest do
  use ExUnit.Case, async: true
  alias WebWidget.Integration.Response

  test "history uses persisted IDs and positions, preserves real timestamps and strips private data" do
    response = %{
      protocol_version: 2,
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
      protocol_version: 2,
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

  test "failed responses display the public body without private error details" do
    response = %{
      protocol_version: 2,
      type: :message_failed,
      conversation_id: "chat",
      message_id: "transport",
      payload: %{
        body: "Your AI credits have run out.",
        error: "PRIVATE_TRACE",
        private_trace: "PRIVATE_TRACE"
      }
    }

    assert {:ok, %{payload: payload}} =
             Response.encode("response.message.failed", response, "12")

    assert payload == %{
             message_id: "transport",
             code: "response_failed",
             message: "Your AI credits have run out."
           }
  end

  test "failed responses without public text use the generic fallback" do
    response = %{
      protocol_version: 2,
      type: :message_failed,
      conversation_id: "chat",
      message_id: "transport",
      payload: %{code: :dispatch_error, error: "PRIVATE_TRACE"}
    }

    for payload <- [response.payload, %{body: nil}, %{body: " \n "}, %{body: 42}] do
      assert {:ok, %{payload: %{message: "Unable to complete this response."}}} =
               Response.encode("response.message.failed", %{response | payload: payload}, "12")
    end
  end

  test "protocol version and request correlation are mandatory" do
    refute Response.correlated?(%{protocol_version: 1, request_id: "r"}, "r")
    refute Response.correlated?(%{protocol_version: 2, request_id: "other"}, "r")
    assert Response.correlated?(%{protocol_version: 2, request_id: "r"}, "r")

    assert Response.validate_version(%{protocol_version: 1}) ==
             {:error, :unsupported_protocol_version}

    assert {:error, :unsupported_protocol_version} =
             Response.encode(
               "response.message.create",
               %{
                 protocol_version: 1,
                 type: :message_create,
                 request_id: "r",
                 conversation_id: "chat",
                 message_id: "a",
                 payload: %{body: "Unsupported"}
               },
               "12"
             )
  end

  test "malformed shared responses and empty correlation never become UI events" do
    for id <- [nil, "", " ", <<255>>, String.duplicate("x", 256)] do
      refute Response.correlated?(%{protocol_version: 2, request_id: id}, id)
    end

    for response <- [
          %{protocol_version: 2, type: :message_failed, payload: nil, conversation_id: "chat"},
          %{protocol_version: 2, type: :message_failed, payload: %{body: "failed"}}
        ] do
      assert {:error, :invalid_response} =
               Response.encode("response.message.failed", response, "12")
    end
  end
end
