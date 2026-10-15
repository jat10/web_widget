defmodule WebWidget.Integration.VerifiedProfileTest do
  use ExUnit.Case, async: true
  alias WebWidget.Integration.VerifiedProfile

  test "normalizes only closed backend profile fields without changing identity values" do
    profile = %{full_name: "Élodie Example", email: "Elodie@example.com", phone: "+33123456789"}
    assert {:ok, ^profile} = VerifiedProfile.normalize(profile)

    assert {:ok, ^profile} =
             VerifiedProfile.normalize(Map.new(profile, fn {k, v} -> {to_string(k), v} end))

    assert {:ok, %{full_name: nil, email: "a@b.example", phone: nil}} =
             VerifiedProfile.normalize(%{"email" => "a@b.example"})

    for absent <- [nil, %{}, %{full_name: nil, email: nil, phone: nil}] do
      assert {:ok, nil} = VerifiedProfile.normalize(absent)
    end
  end

  test "rejects unknown, mixed, malformed and oversized values" do
    for invalid <- [
          [],
          "name",
          42,
          %{role: "admin"},
          %{display_name: "name"},
          %{"email" => "a@b.example", full_name: "name"},
          %{full_name: ""},
          %{full_name: " name"},
          %{full_name: "name\n"},
          %{full_name: <<255>>},
          %{full_name: String.duplicate("a", 256)},
          %{email: "a@b"},
          %{email: "a b@c.example"},
          %{email: false},
          %{email: String.duplicate("a", 250) <> "@b.example"},
          %{phone: "0123456789"},
          %{phone: "+00123456789"},
          %{phone: "+33 123456789"},
          %{phone: "+1234567890123456"},
          %{phone: 123},
          %{full_name: %{name: "nested"}}
        ] do
      assert {:error, :invalid_profile} = VerifiedProfile.normalize(invalid)
    end
  end
end
