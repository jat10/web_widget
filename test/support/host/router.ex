defmodule WebWidget.TestHost.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import WebWidget.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/" do
    pipe_through :browser
    web_widget()
  end

  scope "/support", UnrelatedHostWeb do
    pipe_through :browser
    web_widget("/chat")
  end

  scope "/" do
    web_widget_api()
  end
end
