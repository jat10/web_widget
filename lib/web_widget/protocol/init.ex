defmodule WebWidget.Protocol.Init do
  @moduledoc """
  Internal `widget.init` request. Convert with `to_map/1` before calling the host.

  Initialization defaults to synchronous mode and may resume a conversation.
  The host owns validation and resolution of the supplied identity context.
  """

  @enforce_keys [:widget_id, :user_id]
  defstruct [:widget_id, :user_id, :conversation_id, :prompt_context, mode: :sync]

  @type t :: %__MODULE__{
          widget_id: String.t(),
          user_id: String.t(),
          conversation_id: String.t() | nil,
          prompt_context: String.t() | nil,
          mode: :sync | :async
        }

  @doc "Returns the plain map for the host callback."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = init) do
    init
    |> Map.from_struct()
    |> Map.put(:type, "widget.init")
  end
end
