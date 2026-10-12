defmodule WebWidget.Connector.Private do
  @moduledoc false
  defstruct [:value]
end

defimpl Inspect, for: WebWidget.Connector.Private do
  def inspect(_, _), do: "#WebWidget.Connector.Private<redacted>"
end
