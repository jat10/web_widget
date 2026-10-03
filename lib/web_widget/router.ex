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
      alias Phoenix.LiveView.Router, as: LiveViewRouter
      require LiveViewRouter

      pipeline unquote(session) do
        plug WebWidget.Embedding.FramePolicy
      end

      scope unquote(prefix), alias: false do
        pipe_through unquote(session)

        LiveViewRouter.live_session unquote(session),
          layout: false,
          root_layout: {WebWidgetWeb.Layouts, :widget} do
          LiveViewRouter.live("/:widget_id", WebWidgetWeb.WidgetLive)
        end

        get "/", WebWidget.Embedding.Unavailable, []
        get "/*path", WebWidget.Embedding.Unavailable, []
      end
    end
  end
end
