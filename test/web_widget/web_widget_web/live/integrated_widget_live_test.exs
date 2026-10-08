defmodule WebWidgetWeb.IntegratedWidgetLiveTest do
  use WebWidgetWeb.ConnCase
  import Phoenix.LiveViewTest
  alias WebWidget.Integration.{BindingStore, RuntimeBuilder, SignedIdentity}
  alias WebWidget.TestIntegration.ChatHost

  setup %{conn: conn} do
    id = System.unique_integer([:positive])
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    hooks = %{
      widget_id: id,
      display_name: "Shared widget",
      allowed_domains: ["http://www.example.com"],
      message: ChatHost,
      command: ChatHost,
      response: ChatHost,
      context: ChatHost,
      delivery: ChatHost,
      sink_mfa: {ChatHost, :receive_request, [self()]}
    }

    {:ok, {spec, []}} =
      RuntimeBuilder.build(%{id: id, provider: "web_widget", token: key}, hooks,
        pubsub_server: WebWidget.PubSub,
        identity_verifier: :connector_key,
        identity_issuer: "parent",
        identity_audience: "widget"
      )

    start_supervised!(spec)
    reset = await_reset()
    delay = max(0, (reset + 1) * 1_000 - System.system_time(:millisecond))
    if delay > 0, do: Process.sleep(delay)
    {:ok, view, _} = live(conn, "/widget/#{id}")
    assert_push_event(view, "widget.authentication.required", %{reason: "initial_authentication"})
    %{view: view, key: key, id: id, spec: spec, conn: conn}
  end

  test "connected mount authenticates before shared host initialization", ctx do
    proof = token(ctx)
    conn = put_connect_params(ctx.conn, %{"identity_token" => proof})
    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")

    assert_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "visitor"}, _}
    assert has_element?(view, "#web-widget")

    {:ok, replayed, _} = live(conn, "/widget/#{ctx.id}")
    refute has_element?(replayed, "#web-widget")
    refute_receive {:shared_request, %{type: :conversation_init}, _, _}
  end

  test "verified init is lazy; queued response precedes receipt without losing the answer", ctx do
    refute_receive {:shared_request, _, _, _}
    init(ctx)

    assert_receive {:shared_request, %{type: :conversation_init, conversation_id: nil}, context,
                    _}

    assert context.sender_id == "visitor"
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant", conversation_id: nil}, _, _}
    assert_push_event(ctx.view, "widget.conversation", %{conversation_id: "conversation-1"})
    assert render(ctx.view) =~ "Immediate answer"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "rejects absent proof, claimed-user mismatch and foreign resume", ctx do
    render_event(ctx.view, "widget.context", %{user_id: "visitor"}, %{ok: false})

    render_event(
      ctx.view,
      "widget.context",
      %{identity_token: token(ctx), user_id: "attacker"},
      %{ok: false}
    )

    render_event(
      ctx.view,
      "widget.context",
      %{identity_token: token(ctx, %{conversation_id: "foreign"})},
      %{ok: false}
    )

    refute has_element?(ctx.view, "#web-widget")
  end

  test "all initialization fields come from signed claims and unsigned extensions are rejected",
       ctx do
    proof = token(ctx, %{prompt_context: "Signed context", conversation_id: nil})

    for override <- [
          %{user_id: "visitor"},
          %{conversation_id: "conversation-1"},
          %{prompt_context: "Injected"},
          %{settings: %{theme: "dark"}},
          %{params: %{stylesheet_url: "https://example.com/style.css"}},
          %{future: true}
        ] do
      render_event(ctx.view, "widget.context", Map.put(override, :identity_token, proof), %{
        ok: false
      })

      refute_receive {:shared_request, _, _, _}
    end

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request,
                    %{content: "instant", prompt_context: "Signed context", conversation_id: nil},
                    %{sender_id: "visitor"}, _}
  end

  test "resume loads canonical IDs and untimestamped history before sending", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history, params: %{limit: 50}}, _, _}
    assert render(ctx.view) =~ "Saved answer"
    assert render(ctx.view) =~ "persisted-assistant"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
  end

  test "correlates streaming and refuses duplicate, foreign and late terminals", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    receipt = ChatHost.response(request, :message_edit, "conversation-1", %{body: "Snapshot"})
    ChatHost.publish(context, %{receipt | request_id: "foreign", payload: %{body: "INJECTED"}})
    ChatHost.publish(context, receipt)
    assert render(ctx.view) =~ "Snapshot"
    refute render(ctx.view) =~ "INJECTED"
    render_event(ctx.view, "widget.submit", %{text: "second"}, %{ok: false})

    ChatHost.publish(context, %{
      receipt
      | type: :message_complete,
        payload: %{body: "Final snapshot"}
    })

    ChatHost.publish(context, %{receipt | type: :message_edit, payload: %{body: "LATE"}})
    assert render(ctx.view) =~ "Final snapshot"
    refute render(ctx.view) =~ "LATE"
  end

  test "renewal during streaming preserves delivery and rejects a different sender", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_edit, "conversation-1", %{body: "Before renewal"})
    )

    assert render(ctx.view) =~ "Before renewal"

    render_hook(ctx.view, "widget.auth.renew", %{identity_token: token(ctx)})
    assert_reply(ctx.view, %{ok: true, expires_at: expiry, refresh_at: refresh})
    assert expiry > refresh
    refute_receive {:shared_request, %{type: :conversation_init}, _, _}

    wrong = token(ctx, %{user_id: "another-visitor"})
    render_hook(ctx.view, "widget.auth.renew", %{identity_token: wrong})
    assert_reply(ctx.view, %{ok: false, reason: "invalid_credential"})

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "After renewal"})
    )

    assert render(ctx.view) =~ "After renewal"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "an old expiry timer cannot expire an accepted renewal", ctx do
    {:ok, short} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 2
      )

    render_event(ctx.view, "widget.context", %{identity_token: short}, %{ok: true})
    render_hook(ctx.view, "widget.auth.renew", %{identity_token: token(ctx)})
    assert_reply(ctx.view, %{ok: true})
    Process.sleep(2_100)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "runtime termination clears the session and rejects queued delivery", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    stop_supervised!(ctx.spec.id)

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "REVOKED"})
    )

    assert_push_event(ctx.view, "widget.authentication.required", %{})
    refute has_element?(ctx.view, "#web-widget")
    refute render(ctx.view) =~ "REVOKED"
  end

  test "unknown send outcomes block automatic retry", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "timeout"}, %{ok: false})
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: false})
    refute_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "known-ID timeout recovers through reauthorized history before another send", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :error, "conversation-1", %{code: :timeout, outcome: :unknown})
    )

    assert render(ctx.view) =~ "outcome is unknown"
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, _, _}
    assert render(ctx.view) =~ "Saved answer"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}
  end

  test "connected expiry preserves the mounted view but blocks sending until renewed", ctx do
    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 1
      )

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
    assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
    assert has_element?(ctx.view, "#web-widget")
    render_event(ctx.view, "widget.submit", %{text: "after expiry"}, %{ok: false})
    refute_receive {:shared_request, %{content: "after expiry"}, _, _}
    render_event(ctx.view, "widget.context", %{identity_token: "invalid"}, %{ok: false})
    assert has_element?(ctx.view, "#web-widget")
    render_event(ctx.view, "widget.submit", %{text: "still expired"}, %{ok: false})
    refute_receive {:shared_request, %{content: "still expired"}, _, _}
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "runtime revocation still clears an expired view waiting for renewal", ctx do
    {:ok, proof} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget",
        ttl: 1
      )

    render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
    assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
    assert has_element?(ctx.view, "#web-widget")
    stop_supervised!(ctx.spec.id)
    assert_push_event(ctx.view, "widget.authentication.required", %{})
    refute has_element?(ctx.view, "#web-widget")
  end

  test "terminal failure releases send guard and never exposes private error details", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_failed, "conversation-1", %{
        code: :dispatch_error,
        error: "PRIVATE_TRACE"
      })
    )

    refute render(ctx.view) =~ "PRIVATE_TRACE"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
  end

  test "renewal cannot change sender and a fresh proof can restore the same sender", ctx do
    init(ctx)

    {:ok, wrong} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "another-visitor"},
        issuer: "parent",
        audience: "widget"
      )

    render_event(ctx.view, "widget.context", %{identity_token: wrong}, %{ok: false})
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, %{sender_id: "visitor"}, _}
  end

  defp init(ctx, params \\ %{}) do
    render_event(ctx.view, "widget.context", %{identity_token: token(ctx, params)}, %{
      ok: true
    })
  end

  defp token(ctx, claims \\ %{}),
    do:
      elem(
        SignedIdentity.sign(ctx.key, ctx.id, Map.merge(%{user_id: "visitor"}, claims),
          issuer: "parent",
          audience: "widget"
        ),
        1
      )

  defp render_event(view, event, params, expected) do
    render_hook(view, event, params)

    assert_reply(view, %{ok: ok})
    assert ok == expected.ok

    if expected.ok do
      assert has_element?(view, "#web-widget")
    end
  end

  defp await_reset(remaining \\ 50)
  defp await_reset(0), do: flunk("binding store did not become available")

  defp await_reset(remaining) do
    case BindingStore.reset_cutoff_value() do
      reset when is_integer(reset) ->
        reset

      _ ->
        Process.sleep(100)
        await_reset(remaining - 1)
    end
  end
end
