defmodule WebWidgetWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias WebWidgetWeb.Layouts

  test "normal app layout renders content, navigation, flash messages and reconnect commands" do
    assigns = %{}

    doc =
      ~H"""
      <Layouts.app flash={%{"info" => "Saved", "error" => "Failed"}}>
        <section id="content">Page content</section>
      </Layouts.app>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()

    assert exists?(doc, "header a[href='/'] img[src='/images/logo.svg']")
    assert exists?(doc, "main #content")
    assert text(doc, "#flash-info") =~ "Saved"
    assert text(doc, "#flash-error") =~ "Failed"
    assert exists?(doc, "#flash-group[aria-live=polite]")

    for {id, disconnected_selector} <- [
          {"client-error", ".phx-client-error #client-error"},
          {"server-error", ".phx-server-error #server-error"}
        ] do
      assert exists?(doc, "##{id}[hidden]")

      assert [["show", %{"to" => ^disconnected_selector}], ["remove_attr", %{"attr" => "hidden"}]] =
               commands(doc, "##{id}", "phx-disconnected")

      selector = "##{id}"

      assert [["hide", %{"to" => ^selector}], ["set_attr", %{"attr" => ["hidden", ""]}]] =
               commands(doc, selector, "phx-connected")
    end
  end

  test "widget layout renders content in its mount without application navigation" do
    assigns = %{}

    doc =
      ~H"""
      <Layouts.app flash={%{}} widget>
        <div id="widget-content">Chat</div>
      </Layouts.app>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()

    assert exists?(doc, "main.zaq-widget-mount #widget-content")
    refute exists?(doc, "header")
    refute exists?(doc, "#flash-group")
  end

  test "theme options dispatch the theme event with their selected theme" do
    doc = render_component(&Layouts.theme_toggle/1, %{}) |> LazyHTML.from_fragment()

    for theme <- ["system", "light", "dark"] do
      selector = "button[data-phx-theme=#{theme}]"
      assert exists?(doc, selector)
      assert [["dispatch", %{"event" => "phx:set-theme"}]] = commands(doc, selector, "phx-click")
    end
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()
  defp exists?(doc, selector), do: LazyHTML.to_tree(LazyHTML.query(doc, selector)) != []

  defp commands(doc, selector, attr) do
    [value] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
    Jason.decode!(value)
  end
end
