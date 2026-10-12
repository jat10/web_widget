defmodule WebWidget.ScopeTest do
  use ExUnit.Case, async: false

  alias WebWidget.HostAdapter

  setup do
    WebWidget.TestInfrastructure.setup(pubsub_server: WebWidget.PubSub)
  end

  test "omitted and explicit root scope retain root paths and legacy custom widget_path" do
    for scope <- [[], [scope: "/"]] do
      WebWidget.TestInfrastructure.replace([pubsub_server: WebWidget.PubSub] ++ scope)
      assert {:ok, snippet} = HostAdapter.installation(42, "https://host.example", [])
      assert snippet =~ "https://host.example/web_widget/assets/embed.js"
      assert snippet =~ "https://host.example/widget/42"
    end

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/",
      transport: [widget_path: "/support/chat"]
    )

    assert {:ok, snippet} = HostAdapter.installation(42, "https://host.example", [])
    assert snippet =~ "https://host.example/support/chat/42"
    assert snippet =~ "https://host.example/web_widget/assets/embed.js"
  end

  test "online installation derives both paths from normalized immutable process scope" do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels/",
      token_url: "/api/widget-token"
    )

    Application.put_env(:web_widget, :scope, "/attacker")
    on_exit(fn -> Application.delete_env(:web_widget, :scope) end)

    for config <- [42, %{id: 42, settings: %{"scope" => "/attacker"}}] do
      assert {:ok, snippet} = HostAdapter.installation(config, "https://host.example", [])
      assert snippet =~ "https://host.example/channels/web_widget/assets/embed.js"
      assert snippet =~ "https://host.example/channels/widget/42"
      assert snippet =~ "data-token-url=\"/api/widget-token\""
      refute snippet =~ "attacker"
    end

    assert {:ok, _} = HostAdapter.installation(42, "https://host.example", scope: "/channels/")

    for opts <- [[scope: "/"], [scope: "/other"], [widget_path: "/widget"]] do
      assert {:error, :invalid_widget_installation} =
               HostAdapter.installation(42, "https://host.example", opts)
    end
  end

  test "offline trusted scope and exact derived widget_path agree without double prefixing" do
    :ok = Supervisor.terminate_child(WebWidget.Standalone, WebWidget)

    for opts <- [[scope: "/channels"], [scope: "/channels/", widget_path: "/channels/widget"]] do
      assert {:ok, snippet} = HostAdapter.installation(42, "https://host.example", opts)
      assert snippet =~ "https://host.example/channels/web_widget/assets/embed.js"
      assert snippet =~ "https://host.example/channels/widget/42"
      refute snippet =~ "/channels/channels"
    end

    assert {:error, :invalid_widget_installation} =
             HostAdapter.installation(42, "https://host.example",
               scope: "/channels",
               widget_path: "/widget"
             )
  end

  test "invalid scopes and conflicting legacy paths reject before starting services" do
    for scope <- [
          nil,
          false,
          1,
          [],
          "",
          "channels",
          "//channels",
          "/channels//",
          "/./channels",
          "/channels/..",
          "/channels%2fwidget",
          "/channels?key=private",
          "/channels#frag",
          "/chan nels",
          "/channels\\widget",
          <<255>>,
          "/" <> String.duplicate("x", 1_025)
        ] do
      assert {:error, {:invalid_widget_configuration, :scope, message}} =
               HostAdapter.infrastructure_child_specs(
                 pubsub_server: WebWidget.PubSub,
                 scope: scope
               )

      refute message =~ "private"

      assert {:error, :invalid_widget_installation} =
               HostAdapter.installation(42, "https://host.example", scope: scope)
    end

    assert {:ok, [_]} =
             HostAdapter.infrastructure_child_specs(
               pubsub_server: WebWidget.PubSub,
               scope: "/channels",
               transport: [widget_path: "/channels/widget"]
             )

    for path <- ["/widget", "/support/chat", "/channels/channels/widget"] do
      assert {:error, {:invalid_widget_configuration, :widget_path, _}} =
               HostAdapter.infrastructure_child_specs(
                 pubsub_server: WebWidget.PubSub,
                 scope: "/channels",
                 transport: [widget_path: path]
               )
    end
  end

  test "public macros reject invalid scope and conflicting prefixes at compilation" do
    for {macro_name, prefix} <- [
          {:web_widget, "/widget"},
          {:web_widget_api, "/widget-api"},
          {:web_widget_socket, "/widget"}
        ],
        opts <- [[scope: "//bad"], [scope: nil], [scope: "/channels", unknown: true]] do
      module = if macro_name == :web_widget_socket, do: WebWidget.Endpoint, else: WebWidget.Router

      assert_raise ArgumentError, fn ->
        Code.eval_quoted(
          quote do
            require unquote(module)
            unquote(module).unquote(macro_name)(unquote(prefix), unquote(opts))
          end
        )
      end
    end
  end

  test "scoped macros accept full canonical prefixes without doubling and reject custom or outer scopes" do
    endpoint = WebWidget.TestHost.ScopedEndpoint
    router = WebWidget.TestHost.ScopedRouter
    assert "/channels/widget" in endpoint.__web_widget_prefixes__()

    assert Enum.any?(endpoint.__sockets__(), fn {path, _, _} ->
             path == "/channels/widget/:widget_id/live"
           end)

    paths = Enum.map(router.__routes__(), & &1.path)
    assert "/channels/widget/:widget_id" in paths
    assert "/channels/widget/:widget_id/session" in paths
    assert "/channels/widget-api/:widget_id/disconnect" in paths
    assert "/channels/web_widget/assets/*path" in paths
    refute Enum.any?(paths, &String.contains?(&1, "/channels/channels/"))

    for {module, macro_name} <- [
          {WebWidget.Router, :web_widget},
          {WebWidget.Router, :web_widget_api},
          {WebWidget.Endpoint, :web_widget_socket}
        ] do
      assert_raise ArgumentError, fn ->
        Code.eval_quoted(
          quote do
            require unquote(module)
            unquote(module).unquote(macro_name)("/custom", scope: "/channels")
          end
        )
      end
    end

    assert_raise ArgumentError, ~r/outside another Phoenix path scope/, fn ->
      Code.compile_string("""
      defmodule WebWidget.InvalidNestedScopeRouter do
        use Phoenix.Router
        import WebWidget.Router
        scope "/channels" do
          web_widget("/widget", scope: "/channels")
        end
      end
      """)
    end
  end
end
