defmodule WebWidget.E2EScopedControl do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(%{request_path: "/installation"} = conn, _) do
    {:ok, snippet} = WebWidget.HostAdapter.installation(421, "https://localhost:4023")
    json(conn, %{snippet: snippet})
  end

  def call(%{request_path: "/scope-status"} = conn, _) do
    config = %{id: 421, provider: :web_widget, settings: %{
      "same_site" => "None", "identity_issuer" => "e2e-parent", "identity_audience" => "e2e-widget"}}
    {:ok, status} = WebWidget.HostAdapter.ingress_status(config)
    json(conn, status)
  end

  def call(%{request_path: "/scoped-proof"} = conn, _) do
    conn = fetch_query_params(conn)
    {:ok, proof} = WebWidget.Integration.ControlProof.sign(
      WebWidget.E2ESharedHost.key(), 421, conn.query_params["user_id"],
      issuer: "e2e-parent", audience: "e2e-widget:control")
    json(conn, %{proof: proof})
  end

  def call(conn, _), do: WebWidget.E2EControl.call(conn, WebWidget.E2EControl.init([]))
  defp json(conn, value), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
end
