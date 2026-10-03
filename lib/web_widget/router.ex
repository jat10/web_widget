defmodule WebWidget.Router do
  @moduledoc """
  Mounts the widget in a host browser pipeline with session and CSRF support.

      import WebWidget.Router
      web_widget("/widget")

  Serve the built assets with `WebWidget.Static` before the host router.
  The iframe uses the host's LiveView socket at `/live`.
  """

  defmacro web_widget(prefix \\ "/widget") do
    session = String.to_atom("web_widget_#{__CALLER__.line}")

    quote do
      require Phoenix.LiveView.Router

      scope unquote(prefix), alias: false do
        Phoenix.LiveView.Router.live_session unquote(session),
          layout: false,
          root_layout: {WebWidgetWeb.Layouts, :widget} do
          Phoenix.LiveView.Router.live("/:widget_id", WebWidgetWeb.WidgetLive)
        end
      end
    end
  end
end
