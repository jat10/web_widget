defmodule WebWidget.Embedding.Settings do
  @moduledoc false

  def defaults, do: %{"theme" => "light", "language" => "en"}

  def update(current, patch) when is_map(patch) do
    if Enum.all?(patch, fn
         {"theme", value} -> value in ["auto", "light", "dark"]
         {"language", value} -> value in ["en", "fr", "ar"]
         _ -> false
       end) do
      {:ok, Map.merge(current, patch)}
    else
      {:error, "Invalid settings. Use theme: auto/light/dark and language: en/fr/ar."}
    end
  end

  def update(_, _), do: {:error, "Settings must be an object."}
end
