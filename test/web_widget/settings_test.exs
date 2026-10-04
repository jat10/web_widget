defmodule WebWidget.Embedding.SettingsTest do
  use ExUnit.Case, async: true
  alias WebWidget.Embedding.Settings

  test "partial settings merge and invalid patches fail atomically" do
    defaults = Settings.defaults()
    assert defaults == %{"theme" => "auto", "language" => "en"}

    assert {:ok, %{"theme" => "dark", "language" => "en"}} =
             Settings.update(defaults, %{"theme" => "dark"})

    for theme <- ["auto", "light", "dark"], language <- ["en", "fr", "ar"] do
      patch = %{"theme" => theme, "language" => language}
      assert {:ok, ^patch} = Settings.update(defaults, patch)
    end

    for patch <- [
          nil,
          [],
          "dark",
          %{"theme" => nil},
          %{"theme" => "dark", "language" => "de"},
          %{"user_id" => "other"},
          %{"stylesheet_url" => "/other.css"},
          %{"language" => "ar", "extra" => true}
        ] do
      assert {:error, _} = Settings.update(defaults, patch)
    end
  end
end
