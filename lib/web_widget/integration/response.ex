defmodule WebWidget.Integration.Response do
  @moduledoc false
  alias WebWidget.Integration.Diagnostics
  alias WebWidget.Protocol.Response, as: UIResponse

  @events %{
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }

  def validate_version(%{protocol_version: 2}), do: :ok

  def validate_version(response) when is_map(response),
    do: {:error, :unsupported_protocol_version}

  def validate_version(_), do: {:error, :invalid_response}

  def correlated?(%{protocol_version: 2, request_id: id}, id)
      when is_binary(id) and byte_size(id) in 1..255,
      do: String.valid?(id) and String.trim(id) != ""

  def correlated?(_, _), do: false

  def encode(
        event,
        %{type: type, payload: payload, conversation_id: conversation} = response,
        widget_id
      )
      when is_map(payload) do
    with :ok <- validate_version(response),
         ^event <- Map.get(@events, type),
         {:ok, payload} <- payload(type, payload, Map.get(response, :message_id)),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: event,
             widget_id: widget_id,
             conversation_id: conversation,
             payload: payload
           }) do
      {:ok, normalized}
    else
      {:error, :unsupported_protocol_version} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def encode(_, _, _), do: {:error, :invalid_response}

  def history(response, widget_id) do
    Diagnostics.log(:history_received, response)

    with :ok <- validate_version(response),
         %{type: :conversation_history, payload: %{messages: messages}} <- response,
         true <- is_list(messages) and Enum.all?(messages, &is_map/1),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: "response.conversation.history",
             widget_id: widget_id,
             conversation_id: response.conversation_id,
             payload: %{messages: Enum.map(messages, &history_message/1)}
           }) do
      {:ok, normalized, Enum.map(messages, &Map.get(&1, :position))}
    else
      {:error, :unsupported_protocol_version} = error -> error
      _ -> {:error, :invalid_history}
    end
  end

  def error_text(%{payload: %{code: :timeout}}),
    do:
      "The submission acknowledgement timed out. Its outcome is unknown. Reload known conversation history before trying again."

  def error_text(_), do: "Unable to complete this request."

  defp payload(type, %{body: body}, id)
       when type in [:message_create, :message_edit, :message_complete] and is_binary(body),
       do: {:ok, %{id: id, content: body}}

  defp payload(:typing, %{active: active}, _), do: {:ok, %{active: active}}

  defp payload(
         :message_step,
         %{kind: :activity, state: :running, step_id: step, label: label},
         id
       ),
       do: {:ok, %{id: step, message_id: id, kind: "status", state: "updated", label: label}}

  defp payload(:message_failed, payload, id),
    do: {:ok, %{message_id: id, code: "response_failed", message: failure_message(payload)}}

  defp payload(:error, payload, _),
    do:
      {:ok,
       %{
         request_type: "message.create",
         code: "request_failed",
         message: error_text(%{payload: payload})
       }}

  defp payload(_, _, _), do: :error

  defp failure_message(%{body: body}) when is_binary(body) do
    if String.valid?(body) and String.trim(body) != "",
      do: body,
      else: "Unable to complete this response."
  end

  defp failure_message(_), do: "Unable to complete this response."

  defp history_message(message) when is_map(message) do
    message
    |> Map.take([:id, :role, :content, :timestamp])
    |> Map.put(:id, to_string(Map.get(message, :message_id, Map.get(message, :id))))
    |> history_timestamp(Map.get(message, :provider_sent_at))
  end

  defp history_message(_), do: %{}

  defp history_timestamp(message, nil), do: message
  defp history_timestamp(message, time), do: Map.put(message, :timestamp, time)
end
