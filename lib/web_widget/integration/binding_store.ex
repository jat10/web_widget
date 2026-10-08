defmodule WebWidget.Integration.BindingStore do
  @moduledoc """
  RAM-only, majority-protected JWT page bindings and revocation cutoffs.

  Replica membership is explicit. The service may start before a quorum exists,
  but every operation fails closed until the tables are available on a quorum.
  """

  use GenServer

  @bindings :web_widget_token_bindings
  @revocations :web_widget_user_revocations
  @controls :web_widget_control_requests
  @metadata :web_widget_auth_metadata
  @tables [@bindings, @revocations, @controls, @metadata]
  @tick_ms 1_000
  @prune_limit 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def claim(claims, page_id, now \\ System.system_time(:second)) do
    with true <- valid_claim?(claims) and valid_page?(page_id) and is_integer(now),
         :ok <- available?() do
      transaction(fn ->
        reset = reset_cutoff()
        revoked = revocation_cutoff(claims.issuer, claims.widget_id, claims.user_id)
        key = {claims.issuer, claims.audience, claims.widget_id, claims.jti}

        case :mnesia.read(@bindings, key, :write) do
          [] ->
            if now >= claims.iat and now - claims.iat < binding_window() and
                 claims.iat > reset and claims.iat > revoked and now < claims.exp do
              :mnesia.write({@bindings, key, page_id, claims.user_id, claims.iat, claims.exp})
              :ok
            else
              :mnesia.abort(:stale_or_revoked)
            end

          [{@bindings, ^key, ^page_id, user_id, iat, exp}]
          when user_id == claims.user_id and iat == claims.iat and exp == claims.exp ->
            if iat > reset and iat > revoked and now < exp,
              do: :ok,
              else: :mnesia.abort(:stale_or_revoked)

          _ ->
            :mnesia.abort(:replayed)
        end
      end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  def authorized?(claims, page_id, now \\ System.system_time(:second)) do
    with true <- valid_claim?(claims) and valid_page?(page_id) and is_integer(now),
         :ok <- available?() do
      transaction(fn ->
        reset = reset_cutoff()
        revoked = revocation_cutoff(claims.issuer, claims.widget_id, claims.user_id)
        key = {claims.issuer, claims.audience, claims.widget_id, claims.jti}

        case :mnesia.read(@bindings, key, :write) do
          [{@bindings, ^key, ^page_id, user_id, iat, exp}]
          when user_id == claims.user_id and iat == claims.iat and exp == claims.exp and
                 iat > reset and iat > revoked and now < exp ->
            :ok

          _ ->
            :mnesia.abort(:unauthorized)
        end
      end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  def revoke_user(issuer, widget_id, user_id, request_id, issued_at, now) do
    with true <-
           valid_identifier?(issuer) and is_integer(widget_id) and widget_id > 0 and
             valid_identifier?(user_id) and valid_identifier?(request_id) and
             is_integer(issued_at) and is_integer(now) and issued_at <= now and
             now - issued_at < control_ttl(),
         :ok <- available?() do
      transaction(fn ->
        reset = reset_cutoff()
        request_key = {issuer, widget_id, request_id}
        user_key = {issuer, widget_id, user_id}

        case :mnesia.read(@controls, request_key, :write) do
          [{@controls, ^request_key, ^user_id, ^issued_at, cutoff, _expiry}] ->
            {:ok, cutoff, false}

          [] ->
            if issued_at <= reset, do: :mnesia.abort(:stale_control_request)
            current = revocation_cutoff(issuer, widget_id, user_id)
            cutoff = max(current, now)
            :mnesia.write({@revocations, user_key, cutoff})

            :mnesia.write(
              {@controls, request_key, user_id, issued_at, cutoff, issued_at + control_ttl()}
            )

            {:ok, cutoff, true}

          _ ->
            :mnesia.abort(:request_conflict)
        end
      end)
    else
      _ -> {:error, :unavailable_or_invalid}
    end
  end

  def reset_cutoff_value do
    with :ok <- available?(), do: transaction(&reset_cutoff/0)
  end

  def available? do
    nodes = replica_nodes()
    quorum = div(length(nodes), 2) + 1

    try do
      running = :mnesia.system_info(:running_db_nodes)

      if valid_config?(nodes) and length(Enum.filter(nodes, &(&1 in running))) >= quorum and
           Enum.all?(@tables, &table_ready?(&1, nodes, running, quorum)) do
        :ok
      else
        {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  @impl true
  def init(_opts) do
    nodes = replica_nodes()

    if valid_config?(nodes) do
      case Application.ensure_all_started(:mnesia) do
        {:ok, _} ->
          send(self(), :reconcile)
          {:ok, %{cursors: %{}, nodes: nodes}}

        error ->
          {:stop, error}
      end
    else
      {:stop, :invalid_authentication_config}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile(state.nodes)
    state = if available?() == :ok, do: prune(state), else: state
    Process.send_after(self(), :reconcile, @tick_ms)
    {:noreply, state}
  end

  defp reconcile(nodes) do
    peers = Enum.filter(nodes -- [node()], &(Node.ping(&1) == :pong))
    :mnesia.change_config(:extra_db_nodes, peers)
    running = :mnesia.system_info(:running_db_nodes)
    active = Enum.filter(nodes, &(&1 in running))

    if length(active) >= div(length(nodes), 2) + 1 do
      if Enum.all?(@tables, &(&1 in :mnesia.system_info(:tables))) do
        Enum.each(@tables, &ensure_copy/1)
        ensure_metadata()
      else
        if node() == Enum.min(active), do: create_tables(active)
      end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp create_tables(active) do
    definitions = [
      {@bindings, [:key, :page_id, :user_id, :iat, :exp]},
      {@revocations, [:key, :cutoff]},
      {@controls, [:key, :user_id, :issued_at, :cutoff, :expires_at]},
      {@metadata, [:key, :value]}
    ]

    Enum.each(definitions, fn {table, attrs} ->
      :mnesia.create_table(table,
        attributes: attrs,
        ram_copies: active,
        majority: true,
        type: :ordered_set
      )
    end)

    :mnesia.wait_for_tables(@tables, 5_000)
    ensure_metadata()
  end

  defp ensure_copy(table) do
    if node() not in :mnesia.table_info(table, :ram_copies) do
      :mnesia.add_table_copy(table, node(), :ram_copies)
    end
  end

  defp ensure_metadata do
    transaction(fn ->
      case :mnesia.read(@metadata, :reset_cutoff, :write) do
        [] -> :mnesia.write({@metadata, :reset_cutoff, System.system_time(:second)})
        _ -> :ok
      end
    end)
  end

  defp table_ready?(table, nodes, running, quorum) do
    replicas = :mnesia.table_info(table, :ram_copies)

    node() in replicas and length(replicas) >= quorum and
      Enum.all?(replicas, &(&1 in nodes)) and
      length(Enum.filter(replicas, &(&1 in running))) >= quorum and
      :mnesia.table_info(table, :majority) and
      :mnesia.wait_for_tables([table], 0) == :ok
  end

  defp reset_cutoff do
    case :mnesia.read(@metadata, :reset_cutoff, :read) do
      [{@metadata, :reset_cutoff, cutoff}] when is_integer(cutoff) -> cutoff
      _ -> :mnesia.abort(:missing_reset_cutoff)
    end
  end

  defp revocation_cutoff(issuer, widget_id, user_id) do
    case :mnesia.read(@revocations, {issuer, widget_id, user_id}, :write) do
      [{@revocations, _, cutoff}] -> cutoff
      [] -> -1
    end
  end

  defp transaction(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp prune(state) do
    cursors =
      Enum.reduce([@bindings, @controls], state.cursors, fn table, cursors ->
        cursor = Map.get(cursors, table, :start)
        Map.put(cursors, table, prune_table(table, cursor, @prune_limit))
      end)

    %{state | cursors: cursors}
  end

  defp prune_table(_table, cursor, 0), do: cursor

  defp prune_table(table, cursor, remaining) do
    key =
      if cursor == :start, do: :mnesia.dirty_first(table), else: :mnesia.dirty_next(table, cursor)

    if key == :"$end_of_table" do
      :start
    else
      transaction(fn ->
        case :mnesia.read(table, key, :write) do
          [{^table, ^key, _, _, _, exp}] when table == @bindings ->
            if exp <= System.system_time(:second), do: :mnesia.delete({table, key})

          [{^table, ^key, _, _, _, exp}] when table == @controls ->
            if exp <= System.system_time(:second), do: :mnesia.delete({table, key})

          _ ->
            :ok
        end
      end)

      prune_table(table, key, remaining - 1)
    end
  end

  defp valid_claim?(%{
         issuer: issuer,
         audience: audience,
         widget_id: widget_id,
         user_id: user_id,
         jti: jti,
         iat: iat,
         exp: exp
       }) do
    Enum.all?([issuer, audience, user_id, jti], &valid_identifier?/1) and
      is_integer(widget_id) and widget_id > 0 and is_integer(iat) and
      is_integer(exp) and exp > iat
  end

  defp valid_claim?(_), do: false
  defp valid_page?(page_id), do: valid_identifier?(page_id)
  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) in 1..255

  defp replica_nodes do
    :web_widget
    |> Application.get_env(:authentication, [])
    |> Keyword.get(:replica_nodes, if(node() == :nonode@nohost, do: [node()], else: []))
  end

  defp valid_config?(nodes) do
    opts = Application.get_env(:web_widget, :authentication, [])
    lifetime = Keyword.get(opts, :token_ttl_seconds, 604_800)
    lead = Keyword.get(opts, :refresh_lead_seconds, 300)
    window = Keyword.get(opts, :first_binding_window_seconds, 5)
    control = Keyword.get(opts, :control_proof_ttl_seconds, 30)

    is_list(nodes) and nodes != [] and nodes == Enum.uniq(nodes) and
      node() in nodes and Enum.all?(nodes, &is_atom/1) and
      is_integer(lifetime) and is_integer(lead) and lead > 0 and lifetime > lead and
      is_integer(window) and window > 0 and is_integer(control) and control > 0
  end

  defp binding_window do
    :web_widget
    |> Application.get_env(:authentication, [])
    |> Keyword.get(:first_binding_window_seconds, 5)
  end

  defp control_ttl do
    :web_widget
    |> Application.get_env(:authentication, [])
    |> Keyword.get(:control_proof_ttl_seconds, 30)
  end
end
