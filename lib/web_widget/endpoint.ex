defmodule WebWidget.Endpoint do
  @moduledoc "Endpoint integration for the widget's single scoped LiveView connection."
  alias WebWidget.Embedding.{CookieGuard, Proxy, Session, Socket}

  defmacro web_widget_socket(prefix \\ "/widget", opts \\ []) do
    {prefix, mount} =
      WebWidget.Mount.macro!(
        Macro.expand(prefix, __CALLER__),
        Macro.expand(opts, __CALLER__),
        :widget
      )

    quote do
      unless Module.has_attribute?(__MODULE__, :web_widget_prefixes) do
        Module.register_attribute(__MODULE__, :web_widget_prefixes, accumulate: true)
        Module.register_attribute(__MODULE__, :web_widget_mounts, accumulate: true)
        @before_compile WebWidget.Endpoint

        def call(conn, opts) do
          conn = Proxy.call(conn, __MODULE__, __web_widget_prefixes__())

          guarded =
            if conn.halted, do: conn, else: CookieGuard.call(conn, __web_widget_prefixes__())

          case guarded do
            %{halted: true} = rejected -> rejected
            conn -> super(conn, opts)
          end
        end
      end

      @web_widget_prefixes String.trim_trailing(unquote(prefix), "/")
      @web_widget_mounts unquote(Macro.escape(%{mount | widget_path: prefix}))

      socket unquote(prefix) <> "/:widget_id/live", Socket,
        websocket: [connect_info: [:uri, session: Session.options()]],
        longpoll: [connect_info: [:uri, session: Session.options()]]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    prefixes = Module.get_attribute(env.module, :web_widget_prefixes)
    mounts = Module.get_attribute(env.module, :web_widget_mounts)

    quote do
      @doc false
      def __web_widget_prefixes__, do: unquote(prefixes)
      @doc false
      def __web_widget_mounts__, do: unquote(Macro.escape(mounts))
    end
  end
end
