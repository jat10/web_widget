defmodule WebWidget.Integration.RuntimeBuilder do
  @moduledoc """
  Adapter callbacks for local readiness and installation markup.

  Hosts supervise `WebWidget.Connector` with host inputs. Runtime construction and
  infrastructure recovery are private to each connector.
  """

  alias WebWidget.Integration.{Installation, Readiness}

  def status(widget_id, opts), do: Readiness.status(widget_id, opts)

  def embed_script(widget_id, base_url) do
    with {:ok, infrastructure} <- WebWidget.Configuration.fetch() do
      Installation.script(widget_id, base_url, infrastructure.integration)
    end
  end
end
