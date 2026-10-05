defmodule WebWidget.Integration.Session do
  @moduledoc """
  Server-only verified identity and delivery destination for one caller process.

  Obtain sessions through `WebWidget.Runtime.authenticate/2`; never deserialize
  them from browser data. Runtime replacement invalidates existing sessions.
  The caller owns subscription cleanup and must reauthenticate after reconnect.
  """

  @enforce_keys [
    :widget_id,
    :channel_config_id,
    :sender_id,
    :expires_at,
    :owner,
    :runtime_ref,
    :topic
  ]
  defstruct @enforce_keys

  @doc false
  def valid?(%__MODULE__{} = session, runtime_ref, config_id) do
    session.owner == self() and session.runtime_ref == runtime_ref and
      session.channel_config_id == config_id and
      session.widget_id == Integer.to_string(config_id) and
      is_integer(session.expires_at) and session.expires_at > System.system_time(:second)
  end

  def valid?(_, _, _), do: false
end
