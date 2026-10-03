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

      pipeline unquote(session) do
        plug WebWidget.FramePolicy
      end

      scope unquote(prefix), alias: false do
        pipe_through unquote(session)

        Phoenix.LiveView.Router.live_session unquote(session),
          layout: false,
          root_layout: {WebWidgetWeb.Layouts, :widget} do
          Phoenix.LiveView.Router.live("/:widget_id", WebWidgetWeb.WidgetLive)
        end

        get "/", WebWidget.Unavailable, []
        get "/*path", WebWidget.Unavailable, []
      end
    end
  end
end
