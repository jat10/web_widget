defmodule WebWidget.MockHistory do
  @moduledoc false

  def conversations do
    today = DateTime.utc_now()

    [
      conversation(
        "mock-weekend",
        "A weekend outdoors",
        [
          "Can you help me plan a weekend outside?",
          "Absolutely. Do you prefer walking or cycling?",
          "Walking, somewhere quiet.",
          "Try a morning trail walk followed by a picnic near the lake."
        ],
        today
      ),
      conversation(
        "mock-billing",
        "Understanding my bill",
        [
          "I have a question about my latest bill.",
          "I can help you understand it. Which charge are you looking at?",
          "There are two entries for this month.",
          "One may be a prorated charge from a plan change.",
          "Yes, I upgraded yesterday.",
          "That explains the adjustment. Your next bill should show the regular monthly amount."
        ],
        today
      ),
      conversation(
        "mock-research",
        "Community research",
        [
          "I am looking for local learning opportunities.",
          "Libraries and community centers are good places to start.",
          "Do they offer evening workshops?",
          "Many offer evening sessions in technology, art, and languages.",
          "I would like to learn photography.",
          "Look for an introductory class with a practical outdoor session.",
          "Great, I will check the schedule today."
        ],
        today
      )
    ]
  end

  defp conversation(id, title, texts, now) do
    midpoint = div(length(texts), 2)

    messages =
      texts
      |> Enum.with_index()
      |> Enum.map(fn {content, index} ->
        # Relative dates keep the fixtures on yesterday/today in the viewer's zone.
        day = if index < midpoint, do: DateTime.add(now, -86_400), else: now

        %{
          id: "#{id}-#{index}",
          role: if(rem(index, 2) == 0, do: "user", else: "assistant"),
          content: content,
          timestamp: DateTime.to_iso8601(day)
        }
      end)

    %{id: id, title: title, messages: messages}
  end
end
