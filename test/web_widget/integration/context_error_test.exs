defmodule WebWidget.Integration.ContextErrorTest do
  use ExUnit.Case, async: true

  alias WebWidget.Integration.{ContextError, Response}

  test "ownership denials have the same public response across host codes and operations" do
    replies =
      for operation <- [:initialization, :history],
          code <- [
            :conversation_not_found,
            :conversation_unavailable,
            :conversation_deleted,
            :conversation_unbound,
            :unauthorized,
            :forbidden,
            :permission_denied
          ],
          value <- [code, Atom.to_string(code)] do
        assert {:error, :conversation_unavailable} = ContextError.from_host(value, operation)
        ContextError.reply(:conversation_unavailable)
      end

    assert Enum.uniq(replies) == [
             %{
               ok: false,
               reason: "conversation_unavailable",
               error: "The requested conversation could not be opened."
             }
           ]
  end

  test "unknown host errors and fallback replies cannot leak arbitrary details" do
    for private <- ["PRIVATE_TRACE", %{topic: "web_widget:recipient:private"}, {:private, self()}] do
      assert {:error, :host_initialization_rejected} =
               ContextError.from_host(private, :initialization)

      assert {:error, :history_unavailable} = ContextError.from_host(private, :history)
      assert ContextError.reply(private) == ContextError.reply(:invalid_context)
    end
  end

  test "host error classification happens only after protocol and correlation validation" do
    response = %{
      protocol_version: 2,
      type: :error,
      request_id: "request",
      payload: %{code: :forbidden, error: "PRIVATE_TRACE"}
    }

    assert {:error, :conversation_unavailable} =
             Response.validate_command(response, "request", "selected", :initialization)

    assert {:error, :invalid_host_response} =
             Response.validate_command(response, "other-request", "selected", :initialization)

    assert {:error, :invalid_history_response} =
             Response.validate_command(
               Map.put(response, :conversation_id, "foreign"),
               "request",
               "selected",
               :history
             )

    assert {:error, :unsupported_protocol_version} =
             Response.validate_command(
               %{response | protocol_version: 1},
               "request",
               "selected",
               :initialization
             )
  end

  test "malformed commands have stage-specific safe errors" do
    for response <- [
          nil,
          true,
          %{},
          %{protocol_version: 2, request_id: "request", type: :error, payload: "PRIVATE_TRACE"}
        ] do
      assert {:error, :invalid_host_response} =
               Response.validate_command(response, "request", nil, :initialization)

      assert {:error, :invalid_history_response} =
               Response.validate_command(response, "request", nil, :history)
    end
  end

  test "malformed history IDs fail safely instead of raising during normalization" do
    response = %{
      protocol_version: 2,
      request_id: "request",
      type: :conversation_history,
      conversation_id: "selected",
      payload: %{
        messages: [
          %{message_id: %{private: "PRIVATE_TRACE"}, role: "assistant", content: "Answer"}
        ]
      }
    }

    assert {:error, :invalid_history} = Response.history(response, "42")
  end
end
