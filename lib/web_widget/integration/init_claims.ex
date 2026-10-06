defmodule WebWidget.Integration.InitClaims do
  @moduledoc false
  @keys [:user_id, :conversation_id, :prompt_context]

  def normalize(%{user_id: user} = claims) do
    conversation = Map.get(claims, :conversation_id)
    prompt = Map.get(claims, :prompt_context)

    if Enum.all?(Map.keys(claims), &(&1 in @keys)) and identifier?(user) and
         (is_nil(conversation) or identifier?(conversation)) and valid_prompt?(prompt) do
      {:ok, %{user_id: user, conversation_id: conversation, prompt_context: prompt}}
    else
      {:error, :invalid_init_claims}
    end
  end

  def normalize(_), do: {:error, :invalid_init_claims}

  defp identifier?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) == value and
        byte_size(value) in 1..255

  defp valid_prompt?(nil), do: true

  defp valid_prompt?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 100_000
end
