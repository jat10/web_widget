defmodule Mix.Tasks.WebWidget.Assets.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.WebWidget.Assets.Install

  @files ~w(embed.js app.js app.css web-widget.js web-widget.css widget-client.js)

  setup do
    root = Path.join(System.tmp_dir!(), "widget-assets-#{System.unique_integer([:positive])}")
    source = Path.join(root, "dependency/assets")
    static = Path.join(root, "host/static")
    destination = Path.join(static, "web_widget/assets")
    File.mkdir_p!(source)
    File.mkdir_p!(Path.join(static, "assets"))
    File.write!(Path.join(static, "assets/app.js"), "host app")
    Enum.each(@files, &File.write!(Path.join(source, &1), "widget #{&1}"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{source: source, static: static, destination: destination}
  end

  test "copies nested assets and refreshes the bundle without overwriting host assets", ctx do
    File.mkdir_p!(Path.join(ctx.source, "fonts"))
    File.write!(Path.join(ctx.source, "fonts/widget.woff2"), <<0, 1, 2>>)
    assert :ok = Install.install!(ctx.source, ctx.destination)

    for file <- @files ++ ["fonts/widget.woff2"] do
      assert File.read!(Path.join(ctx.destination, file)) ==
               File.read!(Path.join(ctx.source, file))
    end

    File.write!(Path.join(ctx.source, "embed.js"), "updated embed")
    assert :ok = Install.install!(ctx.source, ctx.destination)
    assert File.read!(Path.join(ctx.destination, "embed.js")) == "updated embed"
    assert File.read!(Path.join(ctx.static, "assets/app.js")) == "host app"
  end

  test "incomplete builds fail before modifying installed assets", ctx do
    Install.install!(ctx.source, ctx.destination)
    File.write!(Path.join(ctx.source, "embed.js"), "incomplete new build")
    File.rm!(Path.join(ctx.source, "app.css"))

    assert_raise Mix.Error, ~r/missing: app.css/, fn ->
      Install.install!(ctx.source, ctx.destination)
    end

    assert File.read!(Path.join(ctx.destination, "embed.js")) == "widget embed.js"
  end

  test "absent builds fail without creating a destination", ctx do
    assert_raise Mix.Error, ~r/Widget assets are not built/, fn ->
      Install.install!(Path.join(ctx.source, "missing"), ctx.destination)
    end

    refute File.exists?(ctx.destination)
  end

  test "installed URLs are served by a host's standard static plug", ctx do
    Install.install!(ctx.source, ctx.destination)
    opts = Plug.Static.init(at: "/", from: ctx.static, only: ~w(assets web_widget))

    for file <- @files do
      conn = Plug.Static.call(Plug.Test.conn(:get, "/web_widget/assets/#{file}"), opts)
      assert conn.status == 200
      assert conn.halted
      assert conn.resp_body == "widget #{file}"
      expected = if String.ends_with?(file, ".js"), do: "text/javascript", else: "text/css"
      assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, expected)
    end

    conn = Plug.Static.call(Plug.Test.conn(:get, "/assets/app.js"), opts)
    assert conn.status == 200
    assert conn.resp_body == "host app"
  end

  test "rejects unsupported arguments" do
    assert_raise Mix.Error, "Usage: mix web_widget.assets.install", fn ->
      Install.run(["--unknown"])
    end
  end
end
