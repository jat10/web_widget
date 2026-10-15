defmodule WebWidget.Endpoint do
  @moduledoc """
  Endpoint integration for the widget's single scoped LiveView connection.

  `web_widget_socket/1,2` installs an overridable `web_widget_normalize/1`
  callback. It defaults to returning the connection unchanged. Hosts can use it
  for trusted ingress normalization before widget proxy/cookie guards and Phoenix
  socket dispatch, without overriding `call/2`. It runs once for every endpoint
  request, including non-widget paths, and may halt to reject a request.

  The host must authenticate the immediate proxy peer (or isolate the backend
  behind ingress that strips and overwrites forwarding headers), reject ambiguous
  forwarding, and preserve `remote_ip` and headers used by the widget proxy guard.
  Neither this callback nor `force_ssl` configuration implicitly enables trust.
  """
  alias WebWidget.Embedding.{CookieGuard, Proxy, Session, Socket}

  @callback web_widget_normalize(Plug.Conn.t()) :: Plug.Conn.t()

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
        @behaviour WebWidget.Endpoint

        @impl WebWidget.Endpoint
        def web_widget_normalize(conn), do: conn
        defoverridable web_widget_normalize: 1

        def call(conn, opts) do
          conn = web_widget_normalize(conn)

          conn =
            if conn.halted,
              do: conn,
              else: Proxy.call(conn, __MODULE__, __web_widget_prefixes__())

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
