defmodule WebWidgetWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias Phoenix.LiveView.JS
  alias Phoenix.LiveView.LiveStream
  alias WebWidgetWeb.CoreComponents, as: Core

  test "flash notices render messages, titles and dismiss commands, and hide absent notices" do
    doc = component(&Core.flash/1, kind: :info, flash: %{"info" => "Saved"}, title: "Success")
    assert text(doc, "#flash-info p") =~ "Saved"
    assert text(doc, "#flash-info p") =~ "Success"
    assert exists?(doc, "#flash-info .hero-information-circle")
    assert exists?(doc, "button[aria-label=close]")

    assert [
             ["push", %{"event" => "lv:clear-flash", "value" => %{"key" => "info"}}],
             ["hide", %{"to" => "#flash-info"}]
           ] = commands(doc, "#flash-info", "phx-click")

    refute exists?(component(&Core.flash/1, kind: :info), "[role=alert]")

    assigns = %{}

    doc =
      document(
        rendered_to_string(~H"""
        <Core.flash id="notice" kind={:error} flash={%{"error" => "fallback"}}>Specific error</Core.flash>
        """)
      )

    assert text(doc, "#notice") =~ "Specific error"
    refute text(doc, "#notice") =~ "fallback"
    assert exists?(doc, "#notice .hero-exclamation-circle")
  end

  test "buttons preserve action attributes and support navigation" do
    assigns = %{}

    doc =
      document(
        rendered_to_string(~H"""
        <Core.button id="save" phx-click="save" disabled>Save</Core.button>
        <Core.button id="primary" variant="primary">Create</Core.button>
        <Core.button id="home" navigate="/home">Home</Core.button>
        <Core.button id="external" href="https://example.com" class="custom">External</Core.button>
        <Core.button id="filter" patch="/?filter=all">Filter</Core.button>
        """)
      )

    assert exists?(doc, "button#save.btn-soft[disabled][phx-click=save]")
    assert exists?(doc, "button#primary.btn-primary")
    refute exists?(doc, "button#primary.btn-soft")
    assert exists?(doc, "a#home[href='/home'][data-phx-link=redirect]")
    assert exists?(doc, "a#external.custom[href='https://example.com']")
    assert exists?(doc, "a#filter[data-phx-link=patch]")
  end

  test "form fields derive names, ids and values and suppress errors for unused input" do
    form = to_form(%{"email" => "bad"}, as: :profile, errors: [email: {"is invalid", []}])
    doc = component(&Core.input/1, field: form[:email], type: "email", label: "Email")
    assert exists?(doc, "#profile_email[name='profile[email]'][value=bad].input-error")
    assert text(doc, "p.text-error") =~ "is invalid"

    unused =
      to_form(%{"email" => "", "_unused_email" => ""},
        as: :profile,
        errors: [email: {"is invalid", []}]
      )

    refute exists?(component(&Core.input/1, field: unused[:email]), "p.text-error")

    roles = to_form(%{"roles" => ["admin"]}, as: :profile)

    doc =
      component(&Core.input/1,
        field: roles[:roles],
        type: "select",
        multiple: true,
        options: [{"Admin", "admin"}]
      )

    assert exists?(
             doc,
             "#profile_roles[multiple][name='profile[roles][]'] option[selected][value=admin]"
           )
  end

  test "hidden and checkbox inputs preserve submission values and disabled state" do
    doc = component(&Core.input/1, type: "hidden", id: "token", name: "token", value: "abc")
    assert exists?(doc, "input#token[type=hidden][value=abc]")

    doc =
      component(&Core.input/1,
        type: "checkbox",
        id: "consent",
        name: "consent",
        value: "true",
        label: "Consent",
        disabled: true,
        form: "settings",
        errors: ["required"]
      )

    assert exists?(doc, "input[type=hidden][value=false][disabled][form=settings]")
    assert exists?(doc, "#consent[type=checkbox][checked][value=true][disabled]")
    assert text(doc, "p.text-error") =~ "required"

    doc =
      component(&Core.input/1, type: "checkbox", name: "consent", checked: false, class: "custom")

    assert exists?(doc, "input[type=checkbox].custom")
    refute exists?(doc, "input[checked]")
  end

  test "select, textarea and text inputs display values, labels and validation errors" do
    doc =
      component(&Core.input/1,
        type: "select",
        id: "role",
        name: "role",
        label: "Role",
        value: "reader",
        options: [{"Reader", "reader"}],
        prompt: "Choose",
        errors: ["invalid"]
      )

    assert exists?(doc, "#role.select-error option[value='']")
    assert exists?(doc, "#role option[selected][value=reader]")
    assert text(doc, "p.text-error") =~ "invalid"

    doc =
      component(&Core.input/1,
        type: "textarea",
        id: "body",
        name: "body",
        label: "Body",
        value: "<draft>",
        rows: 3,
        errors: ["too short"]
      )

    assert exists?(doc, "textarea#body.textarea-error[rows='3']")
    assert text(doc, "textarea") == "<draft>"
    assert text(doc, "p.text-error") =~ "too short"

    doc =
      component(&Core.input/1,
        id: "name",
        name: "name",
        label: "Name",
        value: "Ada",
        class: "custom-input",
        error_class: "invalid-input",
        errors: ["not available"],
        required: true
      )

    assert exists?(doc, "input#name.custom-input.invalid-input[value=Ada][required]")
    assert text(doc, "p.text-error") =~ "not available"
  end

  test "headers and data lists render named slots" do
    assigns = %{}

    doc =
      document(
        rendered_to_string(~H"""
        <Core.header>
          Account
          <:subtitle>Account settings</:subtitle>
          <:actions><button id="edit">Edit</button></:actions>
        </Core.header>
        <Core.list>
          <:item title="Name">Ada</:item>
          <:item title="Role">Admin</:item>
        </Core.list>
        """)
      )

    assert text(doc, "header h1") =~ "Account"
    assert text(doc, "header p") =~ "Account settings"
    assert exists?(doc, "header #edit")
    assert text(doc, "ul.list") =~ "Ada"
    assert length(LazyHTML.to_tree(LazyHTML.query(doc, "li.list-row"))) == 2
  end

  test "tables map rows to columns and actions and attach row click commands" do
    assigns = %{rows: [%{id: 1, name: "Ada"}]}

    doc =
      document(
        rendered_to_string(~H"""
        <Core.table
          id="people"
          rows={@rows}
          row_id={fn row -> "person-#{row.id}" end}
          row_click={fn row -> JS.push("select", value: %{id: row.id}) end}
        >
          <:col :let={row} label="Name">{row.name}</:col>
          <:action :let={row}><a href={"/people/#{row.id}"}>Edit</a></:action>
        </Core.table>
        """)
      )

    assert text(doc, "thead") =~ "Name"
    assert String.trim(text(doc, "#person-1 td:first-child")) == "Ada"
    assert exists?(doc, "#person-1 a[href='/people/1']")

    assert [["push", %{"event" => "select", "value" => %{"id" => 1}}]] =
             commands(doc, "#person-1 td:first-child", "phx-click")

    refute exists?(doc, "#people[phx-update]")
  end

  test "tables render stream row ids and transform stream items for columns" do
    stream = LiveStream.new(:people, 0, [%{id: 2, name: "Grace"}], [])
    assigns = %{rows: stream}

    doc =
      document(
        rendered_to_string(~H"""
        <Core.table id="stream-people" rows={@rows} row_item={fn {_id, person} -> person end}>
          <:col :let={person} label="Name">{person.name}</:col>
        </Core.table>
        """)
      )

    assert exists?(doc, "#stream-people[phx-update=stream] #people-2")
    assert String.trim(text(doc, "#people-2 td")) == "Grace"
    refute exists?(doc, "th .sr-only")
  end

  test "show and hide commands compose with existing actions" do
    assert [["show", %{to: "#panel", time: 300}]] = Core.show("#panel").ops
    assert [["hide", %{to: "#panel", time: 200}]] = Core.hide("#panel").ops

    assert [["push", %{event: "opened"}], ["show", %{to: "#panel"}]] =
             Core.show(JS.push("opened"), "#panel").ops
  end

  test "error translation interpolates counts and selects only errors for the requested field" do
    assert Core.translate_error({"must have %{count} items", count: 2}) == "must have 2 items"

    assert Core.translate_errors([email: {"is invalid", []}, name: {"is required", []}], :email) ==
             ["is invalid"]

    assert Core.translate_errors([], :email) == []
  end

  defp component(fun, assigns), do: document(render_component(fun, assigns))
  defp document(html), do: LazyHTML.from_fragment(html)
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()
  defp exists?(doc, selector), do: LazyHTML.to_tree(LazyHTML.query(doc, selector)) != []

  defp commands(doc, selector, attr) do
    [value] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attr)
    Jason.decode!(value)
  end
end
