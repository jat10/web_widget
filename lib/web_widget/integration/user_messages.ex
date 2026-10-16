defmodule WebWidget.Integration.UserMessages do
  @moduledoc false

  def merge(chat, row, request) do
    existing = Enum.find(chat.state.messages, &(&1.id == row.id))

    with true <- Map.get(chat.user_requests, request, row.id) == row.id,
         true <- not Map.has_key?(chat.streams, row.id),
         true <- consistent_row?(existing, row),
         true <- consistent_position?(chat.message_positions, row) do
      messages =
        if existing,
          do: chat.state.messages,
          else:
            chat.state.messages ++ [Map.merge(row, %{status: "complete", steps: [], error: nil})]

      {:ok,
       %{
         chat
         | state: %{chat.state | messages: messages},
           message_positions: Map.put(chat.message_positions, row.id, row.position),
           user_requests: Map.put(chat.user_requests, request, row.id)
       }
       |> order()}
    else
      _ -> {:error, :conflicting_user_message}
    end
  end

  def order(chat) do
    messages =
      chat.state.messages
      |> Enum.with_index()
      |> Enum.sort_by(fn {message, index} -> order_key(chat, message, index) end)
      |> Enum.map(&elem(&1, 0))

    %{chat | state: %{chat.state | messages: messages}}
  end

  def positions(messages, positions),
    do:
      messages
      |> Enum.zip(positions)
      |> Map.new(fn {message, position} -> {message.id, position} end)

  defp consistent_row?(nil, _), do: true
  defp consistent_row?(%{role: "user", content: content}, %{content: content}), do: true
  defp consistent_row?(_, _), do: false

  defp consistent_position?(positions, row) do
    Map.get(positions, row.id) in [nil, row.position] and
      not Enum.any?(positions, fn {id, position} -> id != row.id and position == row.position end)
  end

  defp order_key(chat, message, index) do
    refs = Map.get(chat.persisted_refs, message.id, %{})

    position =
      chat.message_positions[message.id] || chat.message_positions[refs[:assistant_message_id]]

    stream = Map.get(chat.streams, message.id, %{})
    user = refs[:user_message_id] || chat.user_requests[Map.get(stream, :request_id)]
    user_position = chat.message_positions[user]

    cond do
      is_integer(position) -> {position, 0, index}
      message.role == "assistant" and is_integer(user_position) -> {user_position, 1, index}
      true -> {:unpositioned, 0, index}
    end
  end
end
