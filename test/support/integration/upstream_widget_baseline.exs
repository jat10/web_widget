# Run from ZAQ: MIX_ENV=test mix run <this-file> <upstream-test-paths...>
# Use only when running ZAQ's upstream widget regression tests. Those tests
# assert the default uninstalled-adapter state and install their own fixtures.
# Package integration smokes must keep the real configured RuntimeBuilder.
channels = Application.fetch_env!(:zaq, :channels)
definition = channels |> Map.fetch!(:web_widget) |> Map.delete(:runtime_builder)
Application.put_env(:zaq, :channels, Map.put(channels, :web_widget, definition))
Mix.Task.run("test", System.argv())
