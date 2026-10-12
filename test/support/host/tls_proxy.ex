defmodule WebWidget.TestHost.TLSProxy do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def port(pid), do: GenServer.call(pid, :port)

  def certificates(dir) do
    cert = Path.join(dir, "proxy-cert.pem")
    key = Path.join(dir, "proxy-key.pem")
    ca = Path.join(dir, "proxy-ca.pem")
    ca_key = Path.join(dir, "proxy-ca-key.pem")
    csr = Path.join(dir, "proxy-request.pem")
    extensions = Path.join(dir, "proxy-extensions.cnf")
    File.write!(extensions, "subjectAltName=DNS:localhost\n")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          ca_key,
          "-out",
          ca,
          "-days",
          "1",
          "-subj",
          "/CN=Proxy Test CA"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-new",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          csr,
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          cert,
          "-days",
          "1",
          "-extfile",
          extensions
        ],
        stderr_to_stdout: true
      )

    {cert, key, ca}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok, listener} =
      :ssl.listen(Keyword.get(opts, :port, 0), [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(opts[:certfile]),
        keyfile: String.to_charlist(opts[:keyfile])
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    forwarded_port = Keyword.get(opts, :forwarded_port, port)
    acceptor = spawn_link(fn -> accept(listener, opts[:backend_port], forwarded_port) end)
    {:ok, %{listener: listener, acceptor: acceptor, port: port}}
  end

  @impl true
  def handle_call(:port, _, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:EXIT, pid, _}, %{acceptor: pid} = state),
    do: {:stop, :proxy_acceptor_stopped, state}

  @impl true
  def terminate(_, state) do
    :ssl.close(state.listener)
    Process.exit(state.acceptor, :shutdown)
  end

  defp accept(listener, backend_port, public_port) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> proxy(socket, backend_port, public_port)
            end
          end)

        :ok = :ssl.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept(listener, backend_port, public_port)

      {:error, :closed} ->
        :ok
    end
  end

  defp proxy(socket, backend_port, public_port) do
    with {:ok, tls} <- :ssl.handshake(socket, 5_000),
         {:ok, head} <- headers(tls, ""),
         {:ok, tcp} <-
           :gen_tcp.connect({127, 0, 0, 1}, backend_port, [:binary, active: false], 5_000) do
      [head, body] = String.split(head, "\r\n\r\n", parts: 2)
      [request | headers] = String.split(head, "\r\n")

      headers =
        Enum.reject(headers, fn header ->
          String.starts_with?(String.downcase(header), ["x-forwarded-", "forwarded:"])
        end)

      unless_upgrade = not Enum.any?(headers, &(String.downcase(&1) == "upgrade: websocket"))

      headers =
        if unless_upgrade do
          [
            "connection: close"
            | Enum.reject(headers, &String.starts_with?(String.downcase(&1), "connection:"))
          ]
        else
          headers
        end

      forwarded =
        ["x-forwarded-proto: https", "x-forwarded-host: localhost"] ++
          if(public_port == :omit, do: [], else: ["x-forwarded-port: #{public_port}"])

      :ok =
        :gen_tcp.send(
          tcp,
          Enum.join([request | headers ++ forwarded], "\r\n") <> "\r\n\r\n" <> body
        )

      :ssl.setopts(tls, active: :once)
      :inet.setopts(tcp, active: :once)
      relay(tls, tcp)
      :gen_tcp.close(tcp)
      :ssl.close(tls)
    end
  end

  defp headers(socket, acc) when byte_size(acc) <= 32_768 do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, bytes} <- :ssl.recv(socket, 0, 5_000), do: headers(socket, acc <> bytes)
    end
  end

  defp headers(_, _), do: {:error, :headers_too_large}

  defp relay(tls, tcp) do
    receive do
      {:ssl, ^tls, bytes} ->
        :gen_tcp.send(tcp, bytes)
        :ssl.setopts(tls, active: :once)
        relay(tls, tcp)

      {:tcp, ^tcp, bytes} ->
        :ssl.send(tls, bytes)
        :inet.setopts(tcp, active: :once)
        relay(tls, tcp)

      {:ssl_closed, ^tls} ->
        :ok

      {:tcp_closed, ^tcp} ->
        :ok

      {:ssl_error, ^tls, _} ->
        :ok

      {:tcp_error, ^tcp, _} ->
        :ok
    end
  end
end
