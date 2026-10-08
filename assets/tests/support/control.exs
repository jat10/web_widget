defmodule WebWidget.E2EControl do
  @moduledoc false
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/identity" do
    conn = fetch_query_params(conn)
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(WebWidget.E2ESharedHost.bootstrap(
      if(conn.query_params["short"] == "true", do: 3, else: 604_800),
      conn.query_params["user_id"] || "e2e-visitor")))
  end

  get "/control-proof" do
    conn = fetch_query_params(conn)
    {:ok, proof} = WebWidget.Integration.ControlProof.sign(
      WebWidget.E2ESharedHost.key(), 420, conn.query_params["user_id"],
      issuer: "e2e-parent", audience: "e2e-widget:control")
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{proof: proof}))
  end

  post "/sessions/:id" do
    :ok = WebWidget.E2EHost.configure(id, conn.body_params)
    send_resp(conn, 204, "")
  end

  get "/sessions/:id" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(WebWidget.E2EHost.inspect_session(id)))
  end

  post "/sessions/:id/complete" do
    :ok = WebWidget.E2EHost.finish(id, conn.body_params["fail"] == true)
    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
