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

  def correlated?(%{protocol_version: 1, request_id: id}, id), do: true
  def correlated?(_, _), do: false

  def encode(event, %{type: type, payload: payload} = response, widget_id) do
    with ^event <- Map.get(@events, type),
         {:ok, payload} <- payload(type, payload, Map.get(response, :message_id)),
         {:ok, normalized} <-
           UIResponse.normalize(%{
             type: event,
             widget_id: widget_id,
             conversation_id: response.conversation_id,
             payload: payload
           }) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def encode(_, _, _), do: {:error, :invalid_response}

  def history(response, widget_id) do
    Diagnostics.log(:history_received, response)

    with %{type: :conversation_history, payload: %{messages: messages}} <- response,
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
      _ -> {:error, :invalid_history}
    end
  end

  def error_text(%{payload: %{code: :timeout}}),
    do:
      "The response timed out. Its outcome is unknown. Reload known conversation history before trying again."

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

  defp payload(:message_failed, _, id),
    do:
      {:ok,
       %{message_id: id, code: "response_failed", message: "Unable to complete this response."}}

  defp payload(:error, payload, _),
    do:
      {:ok,
       %{
         request_type: "message.create",
         code: "request_failed",
         message: error_text(%{payload: payload})
       }}

  defp payload(_, _, _), do: :error

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
