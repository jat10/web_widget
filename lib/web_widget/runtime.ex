defmodule WebWidget.Runtime do
  @moduledoc """
  Supervised, server-side configuration for one channel's widgets.

  Start with `{WebWidget.Runtime, config}`. The config contains
  `:channel_config_id`, `:sink_mfa` and `:widgets`. Widget IDs are unique across
  running runtimes and are independent of the owning channel config ID.
  Replace the child to apply configuration changes. Stopping it removes its
  widget registrations. `fetch_widget/1` exposes presentation configuration only.
  Callbacks are invoked in the caller, outside the configuration process.
  """

  use GenServer

  alias WebWidget.Embedding.Origins

  @widget_fields [
    :widget_id,
    :display_name,
    :allowed_domains,
    :stylesheet_url,
    :theme,
    :multiple_conversations
  ]

  def child_spec(config) do
    %{id: {__MODULE__, config.channel_config_id}, start: {__MODULE__, :start_link, [config]}}
  end

  def start_link(config) do
    if valid_config?(config) do
      config =
        config
        |> Map.take([:channel_config_id, :sink_mfa, :widgets, :pubsub_server])
        |> Map.update!(
          :widgets,
          &Enum.map(&1, fn widget ->
            {:ok, origins} =
              Origins.normalize(Map.get(widget, :allowed_domains))

            widget |> Map.take(@widget_fields) |> Map.put(:allowed_domains, origins)
          end)
        )

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

  @doc "Resolves the host-owned PubSub server for a registered widget."
  def pubsub_server(widget_id) do
    with {:ok, config} <- delivery_config(widget_id),
         server when is_atom(server) and not is_nil(server) <- Map.get(config, :pubsub_server) do
      {:ok, server}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Invokes the configured host callback with the event followed by configured arguments."
  def dispatch(%{widget_id: widget_id} = event) do
    with {:ok, %{sink_mfa: {module, function, args}}} <- delivery_config(widget_id) do
      apply(module, function, [event | args])
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp delivery_config(widget_id) do
    case Registry.lookup(WebWidget.RuntimeRegistry, widget_id) do
      [{pid, _}] -> GenServer.call(pid, :delivery_config)
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
  def handle_call(:delivery_config, _from, config) do
    {:reply, {:ok, Map.take(config, [:sink_mfa, :pubsub_server])}, config}
  end

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

  defp valid_widget?(%{widget_id: id, display_name: name} = widget)
       when is_binary(id) and id != "" and is_binary(name) do
    Map.get(widget, :theme, "auto") in ["light", "dark", "auto"] and
      is_boolean(Map.get(widget, :multiple_conversations, false)) and
      match?({:ok, _}, Origins.normalize(Map.get(widget, :allowed_domains))) and
      valid_stylesheet_url?(Map.get(widget, :stylesheet_url))
  end

  defp valid_widget?(_), do: false

  defp valid_stylesheet_url?(nil), do: true

  defp valid_stylesheet_url?(url) when is_binary(url) do
    with false <- String.contains?(url, ["\\", " ", "\t", "\n", "\r"]),
         {:ok, uri} <- URI.new(url) do
      (uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo)) or
        (is_nil(uri.scheme) and is_nil(uri.host) and String.starts_with?(url, "/") and
           not String.starts_with?(url, "//"))
    else
      _ -> false
    end
  end

  defp valid_stylesheet_url?(_), do: false
end
