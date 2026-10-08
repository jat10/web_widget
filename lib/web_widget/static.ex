defmodule WebWidget.Static do
  @moduledoc """
  Serves the dependency's built widget assets at /web_widget/assets.
  `WebWidget.Router.web_widget/1` registers the route in the host router.
  """
  @behaviour Plug

  @impl true
  def init(_opts) do
    Plug.Static.init(
      at: "/web_widget",
      from: :web_widget,
      only: ~w(assets),
      gzip: true,
      headers: [{"access-control-allow-origin", "*"}],
      cache_control_for_etags: "public, max-age=0, must-revalidate"
    )
  end

  @impl true
  def call(conn, opts) do
    case Plug.Static.call(conn, opts) do
      %{halted: true} = conn -> conn
      conn -> conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()
    end
  end
end
