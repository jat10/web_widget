defmodule WebWidgetWeb.WidgetLive do
  use WebWidgetWeb, :live_view

  alias WebWidget.Adapter
  alias WebWidget.Conversation.State, as: Conversation
  alias WebWidget.Embedding.Settings
  alias WebWidget.Integration.Chat
  alias WebWidget.Protocol.Events
  alias WebWidget.Protocol.Response
  alias WebWidget.Runtime
  alias WebWidgetWeb.Localization

  @impl true
  def mount(%{"widget_id" => widget_id}, _session, socket) do
    case WebWidget.Runtime.fetch_widget(widget_id) do
      {:ok, %{allowed_domains: [_ | _]} = widget} ->
        mount_widget(socket, widget)

      _ ->
        {:ok, assign(socket, unavailable: true, page_title: "Widget unavailable")}
    end
  end

  defp mount_widget(socket, widget) do
    locale = "en"
    strings = Localization.strings(locale)

    {:ok,
     assign(socket,
       widget: true,
       integrated: Runtime.integrated?(widget.widget_id),
       chat: nil,
       verified_sender: nil,
       settings: Settings.defaults(),
       widget_locale: locale,
       widget_direction: if(locale == "ar", do: "rtl", else: "ltr"),
       unavailable: false,
       widget_id: widget.widget_id,
       allowed_domains: widget.allowed_domains,
       page_title: widget.display_name,
       widget_stylesheet_url: Map.get(widget, :stylesheet_url),
       parent_context: nil,
       mode: :launcher,
       conversation_opened: false,
       messages: [],
       pending_reply: nil,
       accepted_context: nil,
       subscription: nil,
       conversations: [],
       conversation_states: %{},
       new_chat: false,
       typing: false,
       error: nil,
       config: %{
         title: widget.display_name,
         locale: locale,
         theme: "auto",
         strings: strings,
         multiple_conversations: Map.get(widget, :multiple_conversations, false),
         placeholder: strings["Ask a question…"],
         follow_up_placeholder: strings["Ask a follow-up…"],
         max_length: 2000
       }
     )}
  end

  @impl true
  def render(%{unavailable: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} widget>
      <p id="widget-unavailable" role="alert">Widget unavailable.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} widget>
      <div
        id="widget-state"
        data-mode={@mode}
        data-context-received={to_string(@parent_context != nil)}
      >
        <div
          id="widget-context"
          phx-hook="WidgetContext"
          phx-update="ignore"
          data-allowed-domains={Jason.encode!(@allowed_domains)}
          data-authenticated={to_string(@integrated)}
        />
        <.react
          :if={@parent_context != nil}
          id="web-widget"
          name="WebWidget"
          ssr={false}
          socket={@socket}
          mode={@mode}
          canReopen={@conversation_opened}
          messages={Localization.messages(@messages, @config.locale)}
          isRunning={@pending_reply != nil}
          isTyping={@typing}
          responseError={@error}
          config={@config}
          conversations={@conversations}
          conversationId={if @accepted_context, do: @accepted_context.conversation_id, else: nil}
        />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{unavailable: true}} = socket) do
    {:reply, %{ok: false, error: ui(socket, "Widget unavailable.")}, socket}
  end

  def handle_event("widget.settings.get", _params, socket) do
    {:reply, %{ok: true, settings: socket.assigns.settings}, socket}
  end

  def handle_event("widget.settings.update", %{"settings" => patch}, socket) do
    case Settings.update(socket.assigns.settings, patch) do
      {:ok, settings} ->
        {:reply, %{ok: true, settings: settings}, apply_settings(socket, settings)}

      {:error, error} ->
        {:reply, %{ok: false, error: error}, socket}
    end
  end

  def handle_event("widget.settings.update", _params, socket) do
    {:reply, %{ok: false, error: "Settings must be an object."}, socket}
  end

  def handle_event("widget.close", _params, socket) do
    {:reply, %{ok: true}, assign(socket, :mode, :launcher)}
  end

  def handle_event("widget.open", _params, socket) do
    if socket.assigns.parent_context && socket.assigns.conversation_opened do
      {:reply, %{ok: true}, assign(socket, mode: :conversation, conversation_opened: true)}
    else
      {:reply, %{ok: false, error: ui(socket, "No conversation to reopen.")}, socket}
    end
  end

  def handle_event("widget.conversation.select", %{"id" => id}, socket) do
    cond do
      not conversations_enabled?(socket) ->
        {:reply, %{ok: false, error: ui(socket, "Conversation switching is unavailable.")},
         socket}

      socket.assigns.pending_reply != nil ->
        {:reply,
         %{ok: false, error: ui(socket, "Wait for the current response before switching chats.")},
         socket}

      not Enum.any?(socket.assigns.conversations, &(&1.id == id)) ->
        {:reply, %{ok: false, error: ui(socket, "Conversation unavailable.")}, socket}

      socket.assigns.accepted_context && socket.assigns.accepted_context.conversation_id == id ->
        {:reply, %{ok: true}, socket}

      true ->
        case initialize(cache_current(socket), id) do
          {:ok, socket} ->
            {:reply, %{ok: true}, assign(socket, mode: :conversation, conversation_opened: true)}

          {:error, socket} ->
            {:reply, %{ok: false, error: ui(socket, "Unable to open this conversation.")}, socket}
        end
    end
  end

  def handle_event("widget.conversation.select", _params, socket) do
    {:reply, %{ok: false, error: ui(socket, "Conversation unavailable.")}, socket}
  end

  def handle_event("widget.conversation.new", _params, socket) do
    if conversations_enabled?(socket) and socket.assigns.pending_reply == nil do
      socket = cache_current(socket)
      if socket.assigns.subscription, do: Adapter.unsubscribe(socket.assigns.subscription)

      {:reply, %{ok: true},
       socket
       |> assign(Conversation.new())
       |> assign(
         accepted_context: nil,
         subscription: nil,
         new_chat: true,
         mode: :conversation,
         conversation_opened: true
       )}
    else
      {:reply,
       %{
         ok: false,
         error: ui(socket, "Wait for the current response or enable multiple conversations.")
       }, socket}
    end
  end

  def handle_event("widget.context", params, %{assigns: %{integrated: true}} = socket) do
    with true <- is_nil(socket.assigns.pending_reply),
         {:ok, chat} <- Chat.open(socket.assigns.widget_id, params) do
      if socket.assigns.verified_sender in [nil, chat.session.sender_id] do
        if socket.assigns.chat, do: Chat.close(socket.assigns.chat)

        socket =
          socket
          |> assign_chat(chat)
          |> assign(
            verified_sender: chat.session.sender_id,
            parent_context: %{user_id: chat.session.sender_id}
          )

        socket = restore_mode(socket, chat.conversation_id)

        {:reply,
         %{ok: true, settings: socket.assigns.settings, conversation_id: chat.conversation_id},
         socket}
      else
        Chat.close(chat)
        {:reply, %{ok: false, error: "Reload the widget to change identity."}, socket}
      end
    else
      _ ->
        {:reply, %{ok: false, error: "Unable to authenticate or restore this widget session."},
         socket}
    end
  end

  def handle_event("widget.context", %{"user_id" => user_id} = params, socket) do
    context = %{
      user_id: user_id,
      prompt_context: Map.get(params, "prompt_context"),
      conversation_id: Map.get(params, "conversation_id")
    }

    cond do
      not Enum.all?(Map.keys(params), &(&1 in ["user_id", "conversation_id", "prompt_context"])) or
          not valid_parent_context?(context) ->
        {:reply, %{ok: false, error: ui(socket, "Invalid widget context.")}, socket}

      socket.assigns.parent_context not in [nil, context] ->
        {:reply, %{ok: false, error: ui(socket, "Reload the widget to change context.")}, socket}

      socket.assigns.parent_context == context ->
        {:reply, %{ok: true, settings: socket.assigns.settings}, socket}

      true ->
        settings_reply(
          initialize_context(assign(socket, :parent_context, context), socket),
          socket.assigns.settings
        )
    end
  end

  def handle_event("widget.context", _params, socket) do
    {:reply, %{ok: false, error: ui(socket, "Invalid widget context.")}, socket}
  end

  def handle_event("widget.submit", _params, %{assigns: %{parent_context: nil}} = socket) do
    {:reply, %{ok: false, error: ui(socket, "Widget context with user_id is required.")}, socket}
  end

  def handle_event("widget.submit", %{"text" => text}, %{assigns: %{integrated: true}} = socket)
      when is_binary(text) do
    text = String.trim(text)

    if text != "" and String.length(text) <= socket.assigns.config.max_length and
         socket.assigns.chat do
      case Chat.submit(socket.assigns.chat, text) do
        {:ok, chat} ->
          {:reply, %{ok: true},
           socket
           |> assign_chat(chat)
           |> assign(mode: :conversation, conversation_opened: true)
           |> push_event("widget.conversation", %{conversation_id: chat.conversation_id})}

        {:error, chat, error} ->
          {:reply, %{ok: false, error: error},
           socket |> assign_chat(chat) |> assign(error: error)}
      end
    else
      {:reply, %{ok: false, error: "Enter a message of 1–2000 characters."}, socket}
    end
  end

  def handle_event("widget.submit", %{"text" => text}, socket) when is_binary(text) do
    text = String.trim(text)

    cond do
      socket.assigns.pending_reply != nil ->
        {:reply, %{ok: false, error: ui(socket, "Please wait for the current response.")}, socket}

      text == "" or String.length(text) > socket.assigns.config.max_length ->
        {:reply, %{ok: false, error: ui(socket, "Enter a message of 1–2000 characters.")}, socket}

      true ->
        case initialize(socket) do
          {:ok, socket} ->
            submit(socket, text)

          {:error, socket} ->
            {:reply,
             %{ok: false, error: ui(socket, "Unable to initialize chat. Please try again.")},
             socket}
        end
    end
  end

  def handle_event("widget.submit", _params, socket) do
    {:reply, %{ok: false, error: ui(socket, "Enter a text message.")}, socket}
  end

  @impl true
  def handle_info({:web_response, event, response}, %{assigns: %{chat: chat}} = socket)
      when not is_nil(chat) do
    if Runtime.authorized?(chat.session) do
      {:noreply, assign_chat(socket, Chat.receive_response(chat, event, response))}
    else
      {:noreply, revoke_chat(socket)}
    end
  end

  def handle_info({:widget_session_expired, ref}, %{assigns: %{chat: chat}} = socket)
      when not is_nil(chat) do
    {:noreply, if(chat.session.topic == ref, do: revoke_chat(socket), else: socket)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{chat: chat}} = socket)
      when not is_nil(chat) do
    {:noreply, if(chat.monitor == ref, do: revoke_chat(socket), else: socket)}
  end

  def handle_info({:web_widget_response, _}, %{assigns: %{integrated: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:web_widget_response, event}, socket) do
    with %{conversation_id: conversation_id} <- socket.assigns[:accepted_context],
         {:ok, %{widget_id: widget_id, conversation_id: ^conversation_id} = response} <-
           Response.normalize(event),
         true <- widget_id == socket.assigns.widget_id do
      state = Conversation.apply_event(conversation_state(socket), response)
      {:noreply, socket |> assign(state) |> cache_current()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp restore_mode(socket, nil), do: socket

  defp restore_mode(socket, _id),
    do: assign(socket, mode: :conversation, conversation_opened: true)

  defp assign_chat(socket, chat) do
    socket
    |> assign(chat.state)
    |> assign(
      chat: chat,
      accepted_context: %{user_id: chat.session.sender_id, conversation_id: chat.conversation_id}
    )
  end

  defp revoke_chat(socket) do
    Chat.close(socket.assigns.chat)

    socket
    |> assign(
      chat: nil,
      parent_context: nil,
      accepted_context: nil,
      pending_reply: nil,
      typing: false,
      messages: [],
      error: "Widget session expired. Reconnect to continue."
    )
    |> push_event("widget.authentication.required", %{})
  end

  defp initialize(socket, requested_id \\ :bootstrap)

  defp initialize(%{assigns: %{accepted_context: context}} = socket, :bootstrap)
       when not is_nil(context),
       do: {:ok, socket}

  defp initialize(socket, requested_id) do
    widget_id = socket.assigns.widget_id
    parent = initialization_parent(socket, requested_id)

    with {:ok, event} <- Events.init(widget_id, parent),
         {:ok, response} <- Runtime.dispatch(event),
         {:ok, %{type: "response.widget.initialized", widget_id: ^widget_id} = response} <-
           Response.normalize(response),
         true <- requested_id == :bootstrap or response.conversation_id == requested_id,
         {:ok, subscription} <- Adapter.subscribe(widget_id, response.conversation_id) do
      context = Map.merge(parent, Map.take(response, [:user_id, :conversation_id]))

      candidate =
        socket
        |> assign(Conversation.new())
        |> assign(accepted_context: context, subscription: subscription, new_chat: false)

      candidate
      |> restore_conversation(socket, parent)
      |> finish_initialization(socket, subscription)
    else
      _ -> {:error, socket}
    end
  end

  defp settings_reply({:reply, %{ok: true}, socket}, settings),
    do: {:reply, %{ok: true, settings: settings}, socket}

  defp settings_reply(result, _settings), do: result

  defp initialize_context(
         %{assigns: %{config: %{multiple_conversations: false}}} = candidate,
         _socket
       ),
       do: {:reply, %{ok: true}, candidate}

  defp initialize_context(candidate, socket) do
    case initialize(candidate) do
      {:ok, candidate} ->
        {:reply, %{ok: true}, candidate}

      {:error, _} ->
        {:reply,
         %{ok: false, error: ui(socket, "Unable to load conversations. Please try again.")},
         socket}
    end
  end

  defp initialization_parent(socket, requested_id) do
    parent = socket.assigns.parent_context

    cond do
      requested_id != :bootstrap -> Map.put(parent, :conversation_id, requested_id)
      socket.assigns.new_chat -> Map.put(parent, :conversation_id, nil)
      true -> parent
    end
  end

  defp restore_conversation(candidate, socket, parent) do
    cached =
      Map.get(
        socket.assigns.conversation_states,
        candidate.assigns.accepted_context.conversation_id
      )

    cond do
      cached ->
        {:ok, assign(candidate, cached)}

      parent.conversation_id ||
          (socket.assigns.config.multiple_conversations && not socket.assigns.new_chat) ->
        load_history(candidate)

      true ->
        {:ok, candidate}
    end
  end

  defp finish_initialization({:ok, candidate}, socket, subscription) do
    if socket.assigns.subscription && socket.assigns.subscription != subscription,
      do: Adapter.unsubscribe(socket.assigns.subscription)

    {:ok, candidate}
  end

  defp finish_initialization(_, socket, subscription) do
    if socket.assigns.subscription != subscription, do: Adapter.unsubscribe(subscription)
    {:error, socket}
  end

  defp load_history(socket) do
    widget_id = socket.assigns.widget_id
    conversation_id = socket.assigns.accepted_context.conversation_id

    with {:ok, event} <-
           Events.history(
             widget_id,
             socket.assigns.accepted_context,
             socket.assigns.config.multiple_conversations
           ),
         {:ok, response} <- Runtime.dispatch(event),
         {:ok,
          %{
            type: "response.conversation.history",
            widget_id: ^widget_id,
            conversation_id: ^conversation_id
          } = response} <- Response.normalize(response) do
      socket = assign(socket, Conversation.apply_event(conversation_state(socket), response))

      socket =
        if socket.assigns.config.multiple_conversations do
          Enum.reduce(response.payload.conversations, socket, &cache_history/2)
        else
          socket
        end

      {:ok, cache_current(socket)}
    else
      _ -> :error
    end
  end

  defp cache_history(conversation, socket) do
    state =
      Conversation.apply_event(Conversation.new(), %{
        type: "response.conversation.history",
        payload: %{messages: conversation.messages}
      })

    summary = %{id: conversation.id, title: conversation.title}

    assign(socket,
      conversations: socket.assigns.conversations ++ [summary],
      conversation_states: Map.put(socket.assigns.conversation_states, conversation.id, state)
    )
  end

  defp submit(socket, text) do
    message = %{
      id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      content: text,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }

    with {:ok, event} <-
           Events.create(socket.assigns.widget_id, socket.assigns.accepted_context, message),
         :ok <- Runtime.dispatch(event) do
      state = Conversation.submit(conversation_state(socket), message)

      {:reply, %{ok: true},
       socket
       |> assign(state)
       |> assign(mode: :conversation, conversation_opened: true)
       |> cache_current()}
    else
      _ ->
        {:reply,
         %{ok: false, error: ui(socket, "Unable to send your message. Please try again.")},
         socket}
    end
  end

  defp conversations_enabled?(socket),
    do: socket.assigns.config.multiple_conversations and socket.assigns.parent_context != nil

  defp cache_current(socket) do
    if socket.assigns.config.multiple_conversations && socket.assigns.accepted_context &&
         socket.assigns.messages != [] do
      id = socket.assigns.accepted_context.conversation_id

      conversations =
        if Enum.any?(socket.assigns.conversations, &(&1.id == id)) do
          socket.assigns.conversations
        else
          title = conversation_title(socket)

          [%{id: id, title: title} | socket.assigns.conversations]
        end

      assign(socket,
        conversations: conversations,
        conversation_states:
          Map.put(socket.assigns.conversation_states, id, conversation_state(socket))
      )
    else
      socket
    end
  end

  defp conversation_title(socket) do
    case Enum.find(socket.assigns.messages, &(&1.role == "user")) do
      nil -> ui(socket, "New chat")
      message -> String.slice(message.content, 0, 60)
    end
  end

  defp conversation_state(socket), do: Map.take(socket.assigns, Map.keys(Conversation.new()))

  defp valid_parent_context?(context) do
    nonblank_string?(context.user_id) and
      (is_nil(context.conversation_id) or nonblank_string?(context.conversation_id)) and
      (is_nil(context.prompt_context) or is_binary(context.prompt_context))
  end

  defp apply_settings(socket, settings) do
    strings = Localization.strings(settings["language"])

    config =
      Map.merge(socket.assigns.config, %{
        locale: settings["language"],
        theme: settings["theme"],
        strings: strings,
        placeholder: strings["Ask a question…"],
        follow_up_placeholder: strings["Ask a follow-up…"]
      })

    assign(socket, settings: settings, config: config)
  end

  defp ui(socket, text), do: get_in(socket.assigns, [:config, :strings, text]) || text

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""
end
