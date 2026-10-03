defmodule WebWidget.Message do
  @moduledoc """
  Internal `message.create` or `message.edit` request.

  Messages default to asynchronous creation on the public `default` channel.
  Convert with `to_map/1` before calling the host. The nested message contains
  its ID and text content; conversation history remains owned by the host.
  Set `timestamp` when creating the request, for example with `DateTime.utc_now()`.
  """

  @enforce_keys [:widget_id, :user_id, :conversation_id, :message, :timestamp]
  defstruct [
    :widget_id,
    :user_id,
    :conversation_id,
    :message,
    :timestamp,
    type: "message.create",
    mode: :async,
    channel: "default"
  ]

  @type t :: %__MODULE__{
          widget_id: String.t(),
          user_id: String.t(),
          conversation_id: String.t(),
          message: %{id: String.t(), content: String.t()},
          timestamp: DateTime.t(),
          type: String.t(),
          mode: :sync | :async,
          channel: String.t()
        }

  @doc "Returns the plain map for the host callback."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message), do: Map.from_struct(message)
end
