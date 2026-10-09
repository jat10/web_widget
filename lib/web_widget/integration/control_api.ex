defmodule WebWidget.Integration.ControlAPI do
  @moduledoc """
  Stateless backend control endpoint. Mount with `web_widget_api/1` outside
  the browser session and CSRF pipeline.
  """

  import Plug.Conn

  def init(:disconnect), do: :disconnect

  def call(conn, :disconnect) do
    with true <- json_request?(conn),
         {:ok, conn, body} <- body(conn),
         %{"widget_id" => widget_id} <- conn.path_params,
         %{"user_id" => user_id} <- body,
         true <- map_size(body) == 1 and is_binary(user_id),
         ["Bearer " <> proof] <- get_req_header(conn, "authorization"),
         {:ok, cutoff} <- WebWidget.Runtime.disconnect(widget_id, user_id, proof) do
      reply(conn, 200, %{cutoff: cutoff})
    else
      {:error, :unavailable} -> reply(conn, 503, %{error: "control_unavailable"})
      _ -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  defp body(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, raw, conn} <- read_body(conn, length: 8_192),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, conn, decoded}
    else
      _ -> {:error, :invalid_body}
    end
  end

  defp body(conn), do: {:ok, conn, conn.body_params}

  defp json_request?(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> String.starts_with?(String.downcase(value), "application/json")
      _ -> false
    end
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
