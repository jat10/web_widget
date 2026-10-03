defmodule WebWidget.Runtime do
  @moduledoc """
  Supervised, server-side configuration for one channel's widgets.

  Start with `{WebWidget.Runtime, config}`. The config contains
  `:channel_config_id`, `:sink_mfa` and `:widgets`. Widget IDs are unique across
  running runtimes and are independent of the owning channel config ID.
  Replace the child to apply configuration changes. Stopping it removes its
  widget registrations. `fetch_widget/1` exposes presentation configuration only.
  This runtime does not dispatch message events.
  """

  use GenServer

  @widget_fields [:widget_id, :display_name, :allowed_origins, :stylesheet_url]

  def child_spec(config) do
    %{id: {__MODULE__, config.channel_config_id}, start: {__MODULE__, :start_link, [config]}}
  end

  def start_link(config) do
    if valid_config?(config) do
      config =
        config
        |> Map.take([:channel_config_id, :sink_mfa, :widgets])
        |> Map.update!(:widgets, &Enum.map(&1, fn widget -> Map.take(widget, @widget_fields) end))

      GenServer.start_link(__MODULE__, config)
    else
      {:error, :invalid_runtime_config}
    end
  end

  @doc "Looks up a running widget without exposing its channel ID or sink callback."
  def fetch_widget(widget_id) when is_binary(widget_id) do
    case Registry.lookup(WebWidget.RuntimeRegistry, widget_id) do
      [{pid, _}] -> GenServer.call(pid, {:fetch_widget, widget_id})
      [] -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @impl true
  def init(config) do
    Enum.reduce_while(config.widgets, {:ok, config}, fn widget, acc ->
      case Registry.register(WebWidget.RuntimeRegistry, widget.widget_id, nil) do
        {:ok, _} -> {:cont, acc}
        {:error, {:already_registered, _}} -> {:halt, {:stop, :widget_id_already_registered}}
      end
    end)
  end

  @impl true
  def handle_call({:fetch_widget, widget_id}, _from, config) do
    widget = Enum.find(config.widgets, &(&1.widget_id == widget_id))
    {:reply, if(widget, do: {:ok, widget}, else: {:error, :not_found}), config}
  end

  defp valid_config?(%{
         channel_config_id: id,
         sink_mfa: {module, function, args},
         widgets: widgets
       })
       when not is_nil(id) and is_atom(module) and is_atom(function) and is_list(args) and
              is_list(widgets) do
    Enum.all?(widgets, &valid_widget?/1) and
      length(Enum.uniq_by(widgets, & &1.widget_id)) == length(widgets)
  end

  defp valid_config?(_), do: false

  defp valid_widget?(%{widget_id: id, display_name: name, allowed_origins: origins} = widget)
       when is_binary(id) and id != "" and is_binary(name) and is_list(origins) do
    Enum.all?(origins, &is_binary/1) and
      (is_nil(Map.get(widget, :stylesheet_url)) or is_binary(widget.stylesheet_url))
  end

  defp valid_widget?(_), do: false
end
