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
    |> send_resp(200, Jason.encode!(WebWidget.E2ESharedHost.bootstrap(conn.query_params["conversation_id"])))
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
