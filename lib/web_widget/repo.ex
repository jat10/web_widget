defmodule WebWidget.Repo do
  use Ecto.Repo,
    otp_app: :web_widget,
    adapter: Ecto.Adapters.Postgres
end
