defmodule WebWidget.Static do
  @moduledoc """
  Serves built widget assets at /web_widget/assets. Add before the host router.
  Build the dependency's assets before assembling a release.
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
  def call(conn, opts), do: Plug.Static.call(conn, opts)
end
