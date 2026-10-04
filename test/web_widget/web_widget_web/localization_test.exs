defmodule WebWidgetWeb.LocalizationTest do
  use ExUnit.Case, async: true

  alias WebWidgetWeb.Localization

  test "translations are complete and never change the caller's locale" do
    Gettext.put_locale(WebWidgetWeb.Gettext, "ar")

    for {locale, send} <- [{"en", "Send"}, {"fr", "Envoyer"}, {"ar", "إرسال"}] do
      strings = Localization.strings(locale)
      assert strings["Send"] == send
      assert Map.keys(strings) == Map.keys(Localization.strings("en"))
      assert Enum.all?(strings, fn {_key, text} -> is_binary(text) and text != "" end)
      assert Gettext.get_locale(WebWidgetWeb.Gettext) == "ar"
    end
  end

  test "Arabic summaries use all six plural forms and retain host text" do
    for {count, expected} <- [
          {0, "لم تكتمل أي خطوة"},
          {1, "اكتملت خطوة واحدة"},
          {2, "اكتملت خطوتان"},
          {3, "اكتملت 3 خطوات"},
          {11, "اكتملت 11 خطوة"},
          {100, "اكتملت 100 خطوة"}
        ] do
      message = %{
        content: "Host text",
        error: "Host error",
        steps: List.duplicate(%{state: "completed", label: "Host label"}, count)
      }

      assert [localized] = Localization.messages([message], "ar")
      assert localized.activity.complete == expected
      assert Map.delete(localized, :activity) == message
    end
  end
end
