defmodule WebWidget.E2EControl do
  @moduledoc false
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/identity" do
    conn = fetch_query_params(conn)
    ttl = case Integer.parse(conn.query_params["ttl"] || "") do
      {value, ""} when value in 1..60 -> value
      _ -> if(conn.query_params["short"] == "true", do: 3, else: 604_800)
    end
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(WebWidget.E2ESharedHost.bootstrap(
      ttl, conn.query_params["user_id"] || "e2e-visitor",
      if(conn.query_params["stale"] == "true", do: -6, else: 0))))
  end

  get "/control-proof" do
    conn = fetch_query_params(conn)
    {:ok, proof} = WebWidget.Integration.ControlProof.sign(
      WebWidget.E2ESharedHost.key(), 420, conn.query_params["user_id"],
      issuer: "e2e-parent", audience: "e2e-widget:control")
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{proof: proof}))
  end

  get "/request-count" do
    conn = fetch_query_params(conn)
    count = WebWidget.E2ESharedHost.request_count(
      conn.query_params["user_id"], conn.query_params["content"])
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{count: count}))
  end

  get "/liveview-sessions/:user_id" do
    sessions =
      Phoenix.LiveView.Debug.list_liveviews()
      |> Enum.flat_map(fn
        %{pid: pid, view: WebWidgetWeb.WidgetLive} ->
          case Phoenix.LiveView.Debug.socket(pid) do
            {:ok,
             %{
               assigns: %{
                 chat: %{session: %{sender_id: ^user_id, widget_id: "420", topic: topic}}
               }
             }} ->
              [%{pid: inspect(pid), topic: topic}]

            _ ->
              []
          end

        _ ->
          []
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{sessions: sessions}))
  end

  get "/held-stream/:user_id" do
    status = WebWidget.E2ESharedHost.stream_status(user_id)
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{status: status}))
  end

  post "/held-stream/:user_id/complete" do
    status = if(WebWidget.E2ESharedHost.release_stream(user_id), do: 204, else: 404)
    send_resp(conn, status, "")
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
