defmodule WebWidget.Protocol.Events do
  @moduledoc """
  Prepares widget-to-host events as plain maps without dispatching them.

  Inputs are internal, atom-keyed maps. Supply the widget ID from server-side
  configuration and, for messages, the context accepted by host initialization.
  Callers own message IDs: reuse the same ID when editing or retrying a message.
  Unknown fields are discarded, including browser-supplied event types and modes.
  """

  alias WebWidget.Protocol.Init
  alias WebWidget.Protocol.Message

  import WebWidget.Protocol.Validation, only: [nonblank?: 1]

  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Builds a synchronous init event from the parent bootstrap context."
  @spec init(String.t(), map()) :: result()
  def init(widget_id, %{user_id: user_id} = context) do
    conversation_id = Map.get(context, :conversation_id)
    prompt_context = Map.get(context, :prompt_context)

    cond do
      not nonblank?(widget_id) ->
        {:error, :invalid_widget_id}

      not nonblank?(user_id) ->
        {:error, :invalid_user_id}

      not (is_nil(conversation_id) or nonblank?(conversation_id)) ->
        {:error, :invalid_conversation_id}

      not (is_nil(prompt_context) or is_binary(prompt_context)) ->
        {:error, :invalid_prompt_context}

      true ->
        {:ok,
         Init.to_map(%Init{
           widget_id: widget_id,
           user_id: user_id,
           conversation_id: conversation_id,
           prompt_context: prompt_context
         })}
    end
  end

  def init(_widget_id, _context), do: {:error, :invalid_context}

  @doc "Builds an asynchronous message.create event with a fresh UTC timestamp."
  @spec create(String.t(), map(), map(), String.t()) :: result()
  def create(widget_id, context, message, channel \\ "default") do
    message_event("message.create", widget_id, context, message, channel)
  end

  @doc "Builds an asynchronous message.edit event retaining the existing message ID."
  @spec edit(String.t(), map(), map(), String.t()) :: result()
  def edit(widget_id, context, message, channel \\ "default") do
    message_event("message.edit", widget_id, context, message, channel)
  end

  @doc "Builds a synchronous history request for a host-accepted conversation."
  def history(widget_id, context, include_conversations \\ false)

  def history(
        widget_id,
        %{user_id: user_id, conversation_id: conversation_id},
        include_conversations
      )
      when is_boolean(include_conversations) do
    if nonblank?(widget_id) and nonblank?(user_id) and nonblank?(conversation_id) do
      {:ok,
       %{
         type: "conversation.history.request",
         include_conversations: include_conversations,
         mode: :sync,
         widget_id: widget_id,
         user_id: user_id,
         conversation_id: conversation_id
       }}
    else
      {:error, :invalid_history_context}
    end
  end

  def history(_, _, _), do: {:error, :invalid_history_context}

  defp message_event(
         type,
         widget_id,
         %{user_id: user_id, conversation_id: conversation_id},
         %{
           id: id,
           content: content
         },
         channel
       ) do
    cond do
      not nonblank?(widget_id) ->
        {:error, :invalid_widget_id}

      not nonblank?(user_id) ->
        {:error, :invalid_user_id}

      not nonblank?(conversation_id) ->
        {:error, :invalid_conversation_id}

      not nonblank?(id) ->
        {:error, :invalid_message_id}

      not nonblank?(content) ->
        {:error, :invalid_content}

      not nonblank?(channel) ->
        {:error, :invalid_channel}

      true ->
        {:ok,
         Message.to_map(%Message{
           type: type,
           widget_id: widget_id,
           user_id: user_id,
           conversation_id: conversation_id,
           message: %{id: id, content: content},
           channel: channel,
           timestamp: DateTime.utc_now()
         })}
    end
  end

  defp message_event(_type, _widget_id, _context, _message, _channel),
    do: {:error, :invalid_message_context}
end
