defmodule WebWidget.FramePolicy do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    ancestors =
      case WebWidget.Runtime.fetch_widget(conn.path_params["widget_id"] || "") do
        {:ok, %{allowed_origins: [_ | _] = origins}} -> Enum.join(origins, " ")
        _ -> "'none'"
      end

    register_before_send(conn, fn conn ->
      directives =
        conn
        |> get_resp_header("content-security-policy")
        |> Enum.flat_map(&String.split(&1, ";"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(fn directive ->
          directive == "" or
            String.downcase(hd(String.split(directive))) == "frame-ancestors"
        end)

      conn
      |> delete_resp_header("x-frame-options")
      |> put_resp_header(
        "content-security-policy",
        Enum.join(directives ++ ["frame-ancestors " <> ancestors], "; ")
      )
    end)
  end
end
