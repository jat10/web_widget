defmodule Mix.Tasks.WebWidget.Assets.Install do
  use Mix.Task

  @shortdoc "Installs the web_widget browser bundle into the current host application"
  @moduledoc """
  Run from a Phoenix host that depends on `web_widget`:

      mix web_widget.assets.install

  Copies the dependency's built browser bundle into the current project's
  `priv/static/web_widget/assets`. Include `web_widget` in the host's static
  paths so its existing `Plug.Static` serves `/web_widget/assets/`. The host
  then does not need the `WebWidget.Static` plug.

  Build the widget bundle before installing. Repeat installation after rebuilding
  or upgrading the dependency, and before running the host's `mix phx.digest`.
  This task does not start the host application or its database, edit host source,
  or overwrite the host's own `priv/static/assets` bundle.
  """
  @requirements ["app.config"]
  @required_files ~w(embed.js app.js app.css web-widget.js web-widget.css widget-client.js)

  @impl Mix.Task
  def run([]) do
    source = Application.app_dir(:web_widget, "priv/static/assets")
    destination = Path.expand("priv/static/web_widget/assets")
    install!(source, destination)
    Mix.shell().info("Installed web_widget assets into #{destination}")
  end

  def run(_args), do: Mix.raise("Usage: mix web_widget.assets.install")

  @doc "Copies a complete built widget bundle into the supplied destination."
  def install!(source, destination) do
    missing = Enum.reject(@required_files, &File.regular?(Path.join(source, &1)))

    if missing != [] do
      Mix.raise(
        "Widget assets are not built (missing: #{Enum.join(missing, ", ")}). " <>
          "Run npm --prefix assets run build in the web_widget dependency, then mix web_widget.assets.install."
      )
    end

    File.mkdir_p!(destination)
    File.cp_r!(source, destination)
    :ok
  end
end
