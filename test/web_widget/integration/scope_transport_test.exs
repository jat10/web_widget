defmodule WebWidget.Integration.ScopeTransportTest do
  use ExUnit.Case, async: false
  alias WebWidget.HostAdapter
  alias WebWidget.Integration.{ControlProof, SignedIdentity}
  alias WebWidget.TestHost.{ScopedEndpoint, TLSProxy}
  alias WebWidget.TestIntegration.Host

  setup do
    previous = Application.get_env(:web_widget, ScopedEndpoint)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:web_widget, ScopedEndpoint, previous),
        else: Application.delete_env(:web_widget, ScopedEndpoint)
    end)

    Application.put_env(:web_widget, ScopedEndpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "localhost"],
      secret_key_base: String.duplicate("host", 16),
      live_view: [signing_salt: "host-live"],
      pubsub_server: WebWidget.PubSub,
      check_origin: ["//localhost"],
      http: [ip: {127, 0, 0, 1}, port: 0],
      server: true
    )

    start_supervised!(ScopedEndpoint)

    WebWidget.TestInfrastructure.setup(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      session: [partitioned: false],
      transport: [endpoint: ScopedEndpoint]
    )

    {config, hooks, _} = Host.fixture()
    config = Map.put(config, :name, "Scoped assistant")

    config = %{
      config
      | settings: Map.put(config.settings, "allowed_domains", ["https://parent.example"])
    }

    {:ok, {spec, []}} =
      HostAdapter.build_runtime_specs(
        config,
        Map.take(hooks, [:message, :command, :context, :delivery, :response, :sink_mfa])
      )

    start_supervised!(spec)
    Host.await_runtime(config.id)
    {:ok, {_, port}} = ScopedEndpoint.server_info(:http)

    %{
      config: config,
      url: "http://127.0.0.1:#{port}",
      path: "/channels/widget/#{config.id}",
      port: port
    }
  end

  test "scoped iframe, bundled assets, bootstrap cookies, controls and public readiness agree",
       ctx do
    assert {:ok, snippet} = HostAdapter.installation(ctx.config, "https://localhost")
    assert snippet =~ "/channels/web_widget/assets/embed.js"
    assert snippet =~ ctx.path
    page = get(ctx.url <> ctx.path)
    assert page.status == 200
    assert Req.Response.get_header(page, "set-cookie") == []
    assert page.body =~ "content=\"#{ctx.path}/live\""
    assert page.body =~ "content=\"#{ctx.path}/session\""
    assert page.body =~ "src=\"/channels/web_widget/assets/app.js\""
    assert page.body =~ "href=\"/channels/web_widget/assets/app.css\""

    for file <- [
          "embed.js",
          "app.js",
          "app.css",
          "widget-client.js",
          "web-widget.js",
          "web-widget.css"
        ] do
      response = get(ctx.url <> "/channels/web_widget/assets/" <> file)
      assert response.status == 200
      assert byte_size(response.body) > 100
      assert Req.Response.get_header(response, "set-cookie") == []
    end

    assert get(ctx.url <> "/channels/web_widget/assets/missing.js").status == 404
    assert get(ctx.url <> "/widget/#{ctx.config.id}").status == 503
    assert get(ctx.url <> "/widget/#{ctx.config.id}/session").status == 503
    bootstrap = get(ctx.url <> ctx.path <> "/session")
    [cookie] = Req.Response.get_header(bootstrap, "set-cookie")
    assert String.downcase(cookie) =~ "path=#{ctx.path}"
    assert String.downcase(cookie) =~ "httponly"
    refute String.downcase(cookie) =~ "secure"

    verify =
      get(ctx.url <> ctx.path <> "/session?verify=1", [{"cookie", hd(String.split(cookie, ";"))}])

    assert verify.status == 200
    assert Req.Response.get_header(verify, "set-cookie") == []

    assert {:ok, %{status: :ok, verification: %{session_handshake: :verified}}} =
             HostAdapter.ingress_status(ctx.config)

    assert {:ok, browser_proof} =
             SignedIdentity.sign(ctx.config.token, ctx.config.id, %{user_id: "scoped-user"},
               issuer: "test-issuer",
               audience: "test-audience"
             )

    assert control(ctx, ctx.path |> String.replace("/widget/", "/widget-api/"), browser_proof).status ==
             401

    assert {:ok, proof} =
             ControlProof.sign(ctx.config.token, ctx.config.id, "scoped-user",
               issuer: "test-issuer",
               audience: "test-audience:control"
             )

    assert control(ctx, "/widget-api/#{ctx.config.id}", proof).status == 401
    assert control(ctx, "/channels/widget-api/#{ctx.config.id}", proof).status == 200
  end

  test "compiled endpoint mismatch rejects startup; missing scoped deployment never reports green",
       ctx do
    for {scope, endpoint} <- [{"/channels", WebWidget.TestHost.Endpoint}, {"/", ScopedEndpoint}] do
      assert {:error, {:invalid_widget_configuration, :scope, _}} =
               HostAdapter.infrastructure_child_specs(
                 pubsub_server: WebWidget.PubSub,
                 scope: scope,
                 transport: [endpoint: endpoint]
               )
    end

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/elsewhere",
      session: [partitioned: false]
    )

    Host.await_runtime(ctx.config.id)
    assert {:ok, %{status: status}} = HostAdapter.ingress_status(ctx.config)
    refute status == :ok
    assert get(ctx.url <> ctx.path).status == 503
    assert get(ctx.url <> ctx.path <> "/session").status == 503
  end

  test "secure-policy scoped HTTP feed is locally ready while insecure sessions remain rejected",
       ctx do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      session: [partitioned: true],
      transport: [endpoint: ScopedEndpoint]
    )

    Host.await_runtime(ctx.config.id)

    assert {:ok, %{status: :ok, verification: verification}} =
             HostAdapter.ingress_status(ctx.config)

    assert verification == %{
             scope: :local,
             session_handshake: :not_checked,
             external_https: :not_checked
           }

    for path <- [ctx.path, ctx.path <> "/session"] do
      response = get(ctx.url <> path)
      assert {response.status, response.body} == {503, "https_required"}
      assert Req.Response.get_header(response, "set-cookie") == []
    end
  end

  @tag :tmp_dir
  test "scope stays intact through real proxy TLS, partitioned cookies and WSS", ctx do
    assert_proxy_scope(ctx, :explicit)
  end

  @tag :tmp_dir
  test "default443 public authority supports real proxy TLS and WSS without a forwarded port",
       ctx do
    assert_proxy_scope(ctx, :omit)
  end

  test "native endpoint force_ssl cannot bless malformed or untrusted widget forwarding", ctx do
    endpoint = WebWidget.TestHost.ForceSSLScopedEndpoint
    previous = Application.fetch_env!(:web_widget, endpoint)
    on_exit(fn -> Application.put_env(:web_widget, endpoint, previous) end)

    Application.put_env(
      :web_widget,
      endpoint,
      Keyword.merge(previous,
        secret_key_base: String.duplicate("host", 16),
        live_view: [signing_salt: "host-live"],
        pubsub_server: WebWidget.PubSub,
        server: false,
        url: [host: "localhost", scheme: "https"]
      )
    )

    start_supervised!(endpoint)

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      transport: [endpoint: endpoint],
      proxy: [trusted_proxies: [{127, 0, 0, 1}], public_origin: "https://localhost"]
    )

    Host.await_runtime(ctx.config.id)

    forwarded =
      Plug.Test.conn(:get, ctx.path)
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header("x-forwarded-host", "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})

    valid = endpoint.call(forwarded, [])
    assert valid.status == 200
    assert {valid.scheme, valid.host, valid.port} == {:https, "localhost", 443}

    for path <- [ctx.path, ctx.path <> "/session", ctx.path <> "/live/websocket"],
        {header, value} <- [
          {"x-forwarded-host", "evil.example"},
          {"x-forwarded-proto", "http"},
          {"x-forwarded-port", "80"}
        ] do
      conn =
        %{forwarded | request_path: path, path_info: String.split(path, "/", trim: true)}
        |> Plug.Conn.put_req_header(header, value)

      invalid = endpoint.call(conn, [])
      assert invalid.status == 400
      assert invalid.resp_body == "invalid_widget_proxy"
    end

    untrusted = endpoint.call(%{forwarded | remote_ip: {198, 51, 100, 1}}, [])
    assert untrusted.status in [301, 308]
    assert untrusted.scheme == :http
    assert Plug.Conn.get_req_header(untrusted, "x-forwarded-proto") == []
    assert map_size(untrusted.resp_cookies) == 0
    direct = endpoint.call(Plug.Test.conn(:get, ctx.path <> "/session"), [])
    assert direct.status in [301, 308]
    assert map_size(direct.resp_cookies) == 0
  end

  defp assert_proxy_scope(ctx, forwarding) do
    {cert, key, ca} = TLSProxy.certificates(ctx.tmp_dir)
    proxy_opts = [backend_port: ctx.port, certfile: cert, keyfile: key]

    proxy_opts =
      if forwarding == :omit,
        do: Keyword.put(proxy_opts, :forwarded_port, :omit),
        else: proxy_opts

    proxy = start_supervised!({TLSProxy, proxy_opts})
    port = TLSProxy.port(proxy)
    origin = if forwarding == :omit, do: "https://localhost", else: "https://localhost:#{port}"
    authority = if forwarding == :omit, do: "localhost", else: "localhost:#{port}"

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      session: [partitioned: true],
      transport: [endpoint: ScopedEndpoint],
      proxy: [trusted_proxies: [{127, 0, 0, 1}], public_origin: origin]
    )

    Host.await_runtime(ctx.config.id)

    options = [
      connect_options: [hostname: "localhost", transport_opts: [cacertfile: ca]],
      headers: [{"host", authority}],
      retry: false
    ]

    url = "https://127.0.0.1:#{port}"
    assert Req.get!(url <> ctx.path, options).status == 200
    assert Req.get!(url <> "/channels/web_widget/assets/app.js", options).status == 200
    bootstrap = Req.get!(url <> ctx.path <> "/session", options)
    assert bootstrap.status == 200
    [cookie] = Req.Response.get_header(bootstrap, "set-cookie")

    for attribute <- ["secure", "httponly", "partitioned", "path=#{ctx.path}"] do
      assert String.downcase(cookie) =~ String.downcase(attribute)
    end

    pair = hd(String.split(cookie, ";"))

    verification =
      Req.get!(
        url <> ctx.path <> "/session?verify=1",
        Keyword.put(options, :headers, [{"cookie", pair}, {"origin", origin}, {"host", authority}])
      )

    assert verification.status == 200
    assert Req.Response.get_header(verification, "set-cookie") == []

    for {csrf, request_origin, status} <- [
          {bootstrap.body["csrf_token"], origin, 101},
          {"forged", origin, 403},
          {bootstrap.body["csrf_token"], "https://evil.example", 403}
        ] do
      assert {:ok, connection} =
               Mint.HTTP.connect(:https, "127.0.0.1", port,
                 hostname: "localhost",
                 transport_opts: [cacertfile: ca]
               )

      query = URI.encode_query(%{"_csrf_token" => csrf, "vsn" => "2.0.0"})

      headers = [
        {"host", authority},
        {"origin", request_origin},
        {"cookie", pair},
        {"upgrade", "websocket"},
        {"connection", "Upgrade"},
        {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))},
        {"sec-websocket-version", "13"}
      ]

      assert {:ok, connection, ref} =
               Mint.HTTP.request(
                 connection,
                 "GET",
                 ctx.path <> "/live/websocket?" <> query,
                 headers,
                 nil
               )

      assert_receive message, 2_000
      assert {:ok, connection, responses} = Mint.HTTP.stream(connection, message)
      assert {:status, ref, status} in responses
      Mint.HTTP.close(connection)
    end

    assert {:ok, %{status: :ok, verification: %{session_handshake: :not_checked}}} =
             HostAdapter.ingress_status(ctx.config)

    insecure = get(ctx.url <> ctx.path <> "/session")
    assert insecure.status == 503
    assert Req.Response.get_header(insecure, "set-cookie") == []
  end

  test "real root cookies cannot verify a scoped mount and scoped cookies do not rewrite BO state",
       ctx do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      session: [partitioned: false]
    )

    Host.await_runtime(ctx.config.id)
    root = get(ctx.url <> "/widget/#{ctx.config.id}/session")
    assert root.status == 200
    [cookie] = Req.Response.get_header(root, "set-cookie")
    assert String.downcase(cookie) =~ "path=/widget/#{ctx.config.id}"
    pair = hd(String.split(cookie, ";"))

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      scope: "/channels",
      session: [partitioned: false],
      transport: [endpoint: ScopedEndpoint]
    )

    Host.await_runtime(ctx.config.id)
    verification = get(ctx.url <> ctx.path <> "/session?verify=1", [{"cookie", pair}])
    assert verification.status == 409
    assert Req.Response.get_header(verification, "set-cookie") == []
    fresh = get(ctx.url <> ctx.path <> "/session", [{"cookie", pair}])
    assert fresh.status == 200
    refute fresh.body["csrf_token"] == root.body["csrf_token"]
    [scoped] = Req.Response.get_header(fresh, "set-cookie")
    assert String.downcase(scoped) =~ "path=#{ctx.path}"
    bo = get(ctx.url <> "/bo-session", [{"cookie", hd(String.split(scoped, ";"))}])
    assert bo.status == 200

    for header <- Req.Response.get_header(bo, "set-cookie"),
        do: refute(header =~ "_web_widget_session")

    stale = get(ctx.url <> "/widget/#{ctx.config.id}/session", [{"cookie", pair}])
    assert stale.status == 503
    assert Req.Response.get_header(stale, "set-cookie") == []
  end

  defp get(url, headers \\ []),
    do: Req.get!(url, headers: [{"host", "localhost"} | headers], retry: false)

  defp control(ctx, prefix, proof),
    do:
      Req.post!(ctx.url <> prefix <> "/disconnect",
        headers: [{"host", "localhost"}, {"authorization", "Bearer " <> proof}],
        json: %{user_id: "scoped-user"},
        retry: false
      )
end
