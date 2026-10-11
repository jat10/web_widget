ExUnit.start()

defmodule WebWidget.E2EFixtureSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case

  alias WebWidget.{Connector, Runtime}
  alias WebWidget.Integration.BindingStore

  test "browser fixture starts supervised connectors and survives store controls" do
    {:ok, _} = Application.ensure_all_started(:web_widget)

    children = [
      {Phoenix.PubSub, name: WebWidget.PubSub},
      {WebWidget, pubsub_server: WebWidget.PubSub}
    ]

    start_supervised!(%{
      id: WebWidget.Standalone,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [name: WebWidget.Standalone, strategy: :one_for_one]]}
    })

    Code.require_file("assets/tests/support/shared_host.exs")
    Code.require_file("assets/tests/support/controlled_host.exs")
    Code.require_file("assets/tests/support/control.exs")

    assert WebWidget.E2ESharedHost.ready?()
    children = Supervisor.which_children(WebWidget.Standalone)

    for id <- [420, 421] do
      assert {{Connector, ^id}, pid, :supervisor, [Connector]} =
               List.keyfind(children, {Connector, id}, 0)

      assert is_pid(pid)
      assert {:ok, _} = Runtime.readiness_snapshot(to_string(id), 100)
    end

    assert {:ok, %{same_site: "Lax"}} = Runtime.fetch_widget("420")
    assert {:ok, %{same_site: "None"}} = Runtime.fetch_widget("421")
    assert request(:get, "/ready").status == 200

    previous = BindingStore.reset_cutoff_value()
    now = max(System.system_time(:second), previous + 1)

    claims = %{
      issuer: "e2e-smoke",
      audience: "widget",
      widget_id: 420,
      user_id: "visitor",
      jti: Ecto.UUID.generate(),
      iat: now,
      exp: now + 60
    }

    assert :ok = BindingStore.claim(claims, "page", now)

    assert request(:post, "/auth-store/unavailable").status == 204
    refute WebWidget.E2ESharedHost.ready?()
    assert request(:get, "/ready").status == 503

    assert_raise RuntimeError, ~r/E2E connector runtimes/, fn ->
      WebWidget.E2ESharedHost.await_ready(0)
    end

    assert request(:post, "/auth-store/restore").status == 204
    assert WebWidget.E2ESharedHost.ready?()
    assert BindingStore.reset_cutoff_value() == previous
    assert :ok = BindingStore.authorized?(claims, "page", now)
    assert request(:post, "/auth-store/reset").status == 204
    assert BindingStore.reset_cutoff_value() >= previous
    assert {:error, :unauthorized} = BindingStore.authorized?(claims, "page", now)
    assert WebWidget.E2ESharedHost.ready?()
  end

  defp request(method, path) do
    Plug.Test.conn(method, path)
    |> WebWidget.E2EControl.call(WebWidget.E2EControl.init([]))
  end
end
