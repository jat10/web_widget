defmodule WebWidgetWeb.AssistantLive do
  use WebWidgetWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.react id="assistant-ui" name="AssistantUI" socket={@socket} />
    </Layouts.app>
    """
  end
end
