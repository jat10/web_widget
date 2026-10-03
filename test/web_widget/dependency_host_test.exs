defmodule WebWidget.DependencyHostTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "dependency starts without requiring the host to configure an unused mailer" do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        paths ++ ["-e", "{:ok, _} = Application.ensure_all_started(:web_widget)"],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  @tag timeout: 60_000
  test "host rendering works without mail configuration or standalone services" do
    # A subprocess cannot inherit the standalone endpoint, PubSub, Repo, demo
    # runtime, or application environment started by this project's test suite.
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    script = Path.expand("../support/host/dependency_smoke.exs", __DIR__)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ [script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "1 test, 0 failures"
  end
end
