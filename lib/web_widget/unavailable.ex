defmodule WebWidget.Unavailable do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(404, """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Chat unavailable</title></head>
      <body>
        <main id="widget-unavailable" role="alert">
          <h1>Chat unavailable</h1>
          <p>We couldn’t open this chat. Please check the widget link or contact the website owner.</p>
        </main>
      </body>
    </html>
    """)
  end
end
