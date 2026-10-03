defmodule WebWidget.Adapter do
  @moduledoc "Publishes validated host responses through the widget runtime's configured PubSub server."

  alias WebWidget.Protocol.Response
  alias WebWidget.Runtime

  def send_event(event) do
    with {:ok, event} <- Response.normalize(event),
         {:ok, server} <- Runtime.pubsub_server(event.widget_id) do
      Phoenix.PubSub.broadcast(
        server,
        topic(event.widget_id, event.conversation_id),
        {:web_widget_response, event}
      )
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def subscribe(widget_id, conversation_id) do
    with {:ok, server} <- Runtime.pubsub_server(widget_id),
         :ok <- Phoenix.PubSub.subscribe(server, topic(widget_id, conversation_id)) do
      {:ok, {server, topic(widget_id, conversation_id)}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def unsubscribe({server, topic}), do: Phoenix.PubSub.unsubscribe(server, topic)

  defp topic(widget_id, conversation_id),
    do:
      "web_widget:" <>
        Base.url_encode64(:erlang.term_to_binary({widget_id, conversation_id}), padding: false)
end
