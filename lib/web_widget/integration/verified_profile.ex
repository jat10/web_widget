defmodule WebWidget.Integration.VerifiedProfile do
  @moduledoc false

  @keys [:full_name, :email, :phone]
  @string_keys Enum.map(@keys, &Atom.to_string/1)

  def normalize(nil), do: {:ok, nil}

  def normalize(profile) when is_map(profile) and not is_struct(profile) do
    keys = Map.keys(profile)

    cond do
      Enum.all?(keys, &(&1 in @keys)) ->
        validate(profile)

      Enum.all?(keys, &(&1 in @string_keys)) ->
        validate(Map.new(@keys, &{&1, Map.get(profile, Atom.to_string(&1))}))

      true ->
        {:error, :invalid_profile}
    end
  end

  def normalize(_), do: {:error, :invalid_profile}

  defp validate(profile) do
    profile = Map.new(@keys, &{&1, Map.get(profile, &1)})

    if text?(profile.full_name, 255) and text?(profile.email, 254) and
         text?(profile.phone, 16) and email?(profile.email) and phone?(profile.phone) do
      {:ok, if(Enum.all?(Map.values(profile), &is_nil/1), do: nil, else: profile)}
    else
      {:error, :invalid_profile}
    end
  end

  defp text?(nil, _), do: true

  defp text?(value, maximum) when is_binary(value) do
    byte_size(value) in 1..maximum and String.valid?(value) and
      String.trim(value) == value and not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)
  end

  defp text?(_, _), do: false

  defp email?(nil), do: true

  defp email?(value) when is_binary(value),
    do: Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, value)

  defp email?(_), do: false

  defp phone?(nil), do: true
  defp phone?(value) when is_binary(value), do: Regex.match?(~r/\A\+[1-9][0-9]{6,14}\z/, value)
  defp phone?(_), do: false
end
