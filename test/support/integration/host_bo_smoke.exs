# Run from ZAQ: MIX_ENV=test mix run ../web_widget/test/support/integration/host_bo_smoke.exs
# Uses the real BO and package builder; all database changes roll back in the sandbox.
Code.require_file("test/test_helper.exs")

defmodule WebWidget.HostBOSmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ZaqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Mox
  import Zaq.AccountsFixtures

  alias WebWidget.Integration.RuntimeBuilder
  alias WebWidget.Runtime
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.Supervisor, as: ChannelSupervisor
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo

  test "real BO saves, installs, restarts and disables the package runtime", %{conn: conn} do
    assert Application.fetch_env!(:zaq, :channels).web_widget.runtime_builder == RuntimeBuilder
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    conn = init_test_session(conn, %{user_id: user.id})
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    credential = Zaq.SystemConfigFixtures.ai_credential_fixture()

    agent =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: "Package smoke agent",
        job: "Answer questions",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        conversation_enabled: true,
        active: true
      })
      |> Repo.insert!()

    {:ok, view, _} = live(conn, "/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#widget-adapter-error")
    refute has_element?(view, "#widget-base-url-error")

    name = "Package BO smoke #{System.unique_integer([:positive])}"

    save(view, %{
      "name" => name,
      "allowed_domains" => "http://localhost:4010",
      "enabled" => "false",
      "agent_id" => to_string(agent.id)
    })

    config = Repo.get_by!(ChannelConfig, name: name)
    refute config.enabled
    rule = IncomingMessageRouting.get_rule(%{channel_config_id: config.id})
    assert rule.routing_mode == :agent
    assert rule.configured_agent_id == agent.id

    on_exit(fn ->
      WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"})
    end)

    view |> element("#generate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    key = Repo.get!(ChannelConfig, config.id).token
    assert is_binary(key) and byte_size(key) >= 43
    save(view, %{"enabled" => "true"})
    refute has_element?(view, "#widget-recovery-error")

    assert {:ok, %{state_pid: initial, listener_pids: []}} =
             ChannelSupervisor.lookup_runtime("web_widget_#{config.id}")

    assert {:ok, public} = Runtime.fetch_widget(to_string(config.id))
    assert public.allowed_domains == ["http://localhost:4010"]
    refute inspect(public) =~ key
    assert Runtime.authenticate(to_string(config.id), key) == {:error, :unauthorized}

    view |> element("#close-widget-modal") |> render_click()
    view |> element("#widget-script-#{config.id}") |> render_click()
    {:ok, snippet} = RuntimeBuilder.embed_script(config.id, "https://zaq.example.test")
    assert has_element?(view, "#widget-install-script", snippet)
    refute has_element?(view, "script[data-widget-id='#{config.id}']")
    refute snippet =~ key
    assert snippet =~ "/web_widget/assets/embed.js"

    view |> element("#edit-widget-#{config.id}") |> render_click()
    monitor = Process.monitor(initial)
    save(view, %{"name" => name <> " updated"})
    assert_receive {:DOWN, ^monitor, :process, ^initial, :shutdown}

    assert {:ok, %{state_pid: updated}} =
             ChannelSupervisor.lookup_runtime("web_widget_#{config.id}")

    assert {:ok, %{display_name: display_name}} = Runtime.fetch_widget(to_string(config.id))
    assert display_name == name <> " updated"

    monitor = Process.monitor(updated)
    view |> element("#rotate-widget-key") |> render_click()
    assert_receive {:DOWN, ^monitor, :process, ^updated, :shutdown}
    assert Repo.get!(ChannelConfig, config.id).token != key

    assert {:ok, %{state_pid: rotated}} =
             ChannelSupervisor.lookup_runtime("web_widget_#{config.id}")

    monitor = Process.monitor(rotated)
    save(view, %{"enabled" => "false"})
    assert_receive {:DOWN, ^monitor, :process, ^rotated, :shutdown}
    refute Repo.get!(ChannelConfig, config.id).enabled
    assert {:error, :not_found} = Runtime.fetch_widget(to_string(config.id))
    save(view, %{"enabled" => "true"})
    assert {:ok, _} = Runtime.fetch_widget(to_string(config.id))
  end

  defp save(view, params),
    do: view |> element("#widget-config-form") |> render_submit(%{"widget" => params})
end
