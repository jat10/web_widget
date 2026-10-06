defmodule WebWidget.Protocol.Validation do
  @moduledoc false

  def nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
