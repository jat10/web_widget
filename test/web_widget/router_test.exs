defmodule WebWidget.RouterTest do
  use ExUnit.Case, async: true

  test "a host can compile the widget macro with its default and a custom prefix" do
    # Compile during the test to exercise the macro as a dependency host would.
    # This module is private to this test and does not replace the app router.
    Code.compile_string("""
        defmodule WebWidget.RouterTest.Host do
          use Phoenix.Router
          import WebWidget.Router

          web_widget()
          web_widget("/assistant")
        end
    """)

    for prefix <- ["/widget", "/assistant"] do
      route =
        Phoenix.Router.route_info(
          WebWidget.RouterTest.Host,
          "GET",
          prefix <> "/support",
          "localhost"
        )

      assert route.plug == Phoenix.LiveView.Plug
      assert route.path_params == %{"widget_id" => "support"}

      for suffix <- ["", "/support/extra"] do
        route =
          Phoenix.Router.route_info(
            WebWidget.RouterTest.Host,
            "GET",
            prefix <> suffix,
            "localhost"
          )

        assert route.plug == WebWidget.Embedding.Unavailable
      end
    end
  end
end
