defmodule WebWidget.Integration.ContextError do
  @moduledoc false

  @messages %{
    invalid_context: "Unable to update the widget context.",
    invalid_context_fields:
      "Context accepts only conversation_id and prompt_context. Use a nonblank conversation ID and a string or null prompt context.",
    submission_pending:
      "Wait for the current submission acknowledgement before updating context.",
    session_unauthorized:
      "The widget session is no longer authorized. Reconnect before updating context.",
    authentication_required: "Authenticate the widget before updating context.",
    conversation_required:
      "Include conversation_id to update an existing or blocked conversation.",
    conversation_unavailable: "The requested conversation could not be opened.",
    host_unavailable: "The conversation host is unavailable. Try again later.",
    host_initialization_rejected: "The host rejected conversation initialization.",
    invalid_host_response: "The host returned an invalid conversation initialization response.",
    unsupported_protocol_version:
      "Unsupported host protocol version. This widget requires version 2.",
    delivery_binding_missing:
      "The host initialization response did not include a delivery binding.",
    invalid_delivery_binding: "The host returned an invalid delivery binding.",
    delivery_binding_changed:
      "The host returned a different delivery binding for this widget session.",
    history_unavailable: "The conversation history could not be loaded.",
    invalid_history_response: "The host returned an invalid conversation history response."
  }

  @ownership_codes ~w(conversation_not_found conversation_unavailable conversation_deleted conversation_unbound unbound_conversation unauthorized forbidden not_found permission_denied)a
  @host_codes @ownership_codes ++
                ~w(unavailable timeout node_unavailable unsupported_protocol_version missing_delivery_descriptor invalid_delivery_descriptor conversation_id_required invalid_response_payload)a

  def reply(reason) do
    reason = if Map.has_key?(@messages, reason), do: reason, else: :invalid_context
    %{ok: false, reason: Atom.to_string(reason), error: Map.fetch!(@messages, reason)}
  end

  def from_host(code, operation) do
    code = Enum.find(@host_codes, :unknown, &(code == &1 or code == Atom.to_string(&1)))

    case code do
      code when code in @ownership_codes -> {:error, :conversation_unavailable}
      :unsupported_protocol_version -> {:error, :unsupported_protocol_version}
      :missing_delivery_descriptor -> {:error, :delivery_binding_missing}
      :invalid_delivery_descriptor -> {:error, :invalid_delivery_binding}
      :conversation_id_required -> {:error, :conversation_required}
      :invalid_response_payload -> invalid_response(operation)
      _ -> unavailable(code, operation)
    end
  end

  def invalid_response(:initialization), do: {:error, :invalid_host_response}
  def invalid_response(:history), do: {:error, :invalid_history_response}

  defp unavailable(code, :initialization)
       when code in [:unavailable, :timeout, :node_unavailable],
       do: {:error, :host_unavailable}

  defp unavailable(_, :initialization), do: {:error, :host_initialization_rejected}
  defp unavailable(_, :history), do: {:error, :history_unavailable}
end
