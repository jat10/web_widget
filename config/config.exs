# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :web_widget,
  start_web_server: true,
  ecto_repos: [WebWidget.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :web_widget, WebWidgetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WebWidgetWeb.ErrorHTML, json: WebWidgetWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WebWidget.PubSub,
  live_view: [signing_salt: "5AWTtc+k"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :web_widget, WebWidget.Mailer, adapter: Swoosh.Adapters.Local

# React components render in the browser; no Node.js SSR service is required.
config :live_react, ssr: false

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
