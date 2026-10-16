defmodule WebWidgetWeb.IntegratedWidgetLiveTest do
  use WebWidgetWeb.ConnCase
  import Phoenix.LiveViewTest
  alias WebWidget.Connector.RuntimeConfig
  alias WebWidget.Integration.{BindingStore, ControlProof, SignedIdentity}
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
      RuntimeConfig.prepare(
        %{
          id: id,
          provider: "web_widget",
          token: key,
          settings: %{
            "identity_issuer" => "parent",
            "identity_audience" => "widget",
            "same_site" => "Lax"
          }
        },
        hooks,
        pubsub_server: WebWidget.PubSub,
        identity_verifier: :connector_key
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

    {:ok, wrong_issuer} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "wrong",
        audience: "widget"
      )

    {:ok, wrong_audience} =
      SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
        issuer: "parent",
        audience: "wrong"
      )

    {:ok, wrong_widget} =
      SignedIdentity.sign(ctx.key, ctx.id + 1, %{user_id: "visitor"},
        issuer: "parent",
        audience: "widget"
      )

    for rejected_proof <- [wrong_issuer, wrong_audience, wrong_widget, proof <> "x"] do
      rejected_conn = put_connect_params(ctx.conn, %{"identity_token" => rejected_proof})
      {:ok, rejected, _} = live(rejected_conn, "/widget/#{ctx.id}")
      refute has_element?(rejected, "#web-widget")
      refute_receive {:shared_request, %{type: :conversation_init}, _, _}
    end

    conn = put_connect_params(ctx.conn, %{"identity_token" => proof})
    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")

    assert_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "visitor"}, _}
    assert has_element?(view, "#web-widget")

    {:ok, replayed, _} = live(conn, "/widget/#{ctx.id}")
    refute has_element?(replayed, "#web-widget")
    refute_receive {:shared_request, %{type: :conversation_init}, _, _}
  end

  test "connected mount authorizes a selected conversation before restoring history", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")

    assert_receive {:shared_request,
                    %{type: :conversation_init, conversation_id: "conversation-1"}, _, _}

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert render(view) =~ "Saved answer"

    rejected =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "foreign"
      })

    {:ok, denied, _} = live(rejected, "/widget/#{ctx.id}")
    refute has_element?(denied, "#web-widget")

    assert_receive {:shared_request, %{type: :conversation_init, conversation_id: "foreign"}, _,
                    _}

    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
  end

  test "failed mount retains untrusted selection until authenticated restoration", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => "expired",
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
    refute_receive {:shared_request, _, _, _}
    render_event(view, "widget.context", %{identity_token: token(ctx)}, %{ok: true})

    assert_receive {:shared_request,
                    %{type: :conversation_init, conversation_id: "conversation-1"}, _, _}

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert render(view) =~ "Saved answer"
    render_event(view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request, %{content: "instant", conversation_id: "conversation-1"}, _,
                    _}

    assert render(view) =~ "Immediate answer"
  end

  test "repeated recovery keeps response delivery and signed revocation", ctx do
    for _ <- 1..2 do
      {:ok, proof} =
        SignedIdentity.sign(ctx.key, ctx.id, %{user_id: "visitor"},
          issuer: "parent",
          audience: "widget",
          ttl: 1
        )

      render_event(ctx.view, "widget.context", %{identity_token: proof}, %{ok: true})
      assert_push_event(ctx.view, "widget.authentication.required", %{}, 1500)
      init(ctx)
      render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
      assert_receive {:shared_request, %{content: "instant"}, _, _}
      assert render(ctx.view) =~ "Immediate answer"
      chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
      assert chat.pending_submission == nil

      for {server, topic} <- [chat.subscription, chat.revocation_subscription] do
        assert Enum.count(Registry.lookup(server, topic), fn {pid, _} -> pid == ctx.view.pid end) ==
                 1

        pid = ctx.view.pid
        probe = {:subscription_probe, make_ref()}
        :erlang.trace(pid, true, [:receive])
        Phoenix.PubSub.broadcast(server, topic, probe)
        assert_receive {:trace, ^pid, :receive, ^probe}
        refute_receive {:trace, ^pid, :receive, ^probe}
        :erlang.trace(pid, false, [:receive])
      end
    end

    {:ok, proof} =
      ControlProof.sign(ctx.key, ctx.id, "visitor", issuer: "parent", audience: "widget:control")

    assert %{status: 200} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> proof)
             |> Plug.Conn.put_req_header("content-type", "application/json")
             |> post("/widget-api/#{ctx.id}/disconnect", Jason.encode!(%{user_id: "visitor"}))

    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  test "replacement initialization and history failures retire the previous owner", ctx do
    initial_monitors = Process.info(ctx.view.pid, :monitors)

    for failure <- [:conversation_init, :conversation_history] do
      init(ctx, %{conversation_id: "conversation-1"})
      old = :sys.get_state(ctx.view.pid).socket.assigns.chat
      send(ctx.view.pid, {:widget_session_expired, old.session.topic, old.auth_generation})
      assert_push_event(ctx.view, "widget.authentication.required", %{reason: "expired"})

      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_failure, failure)
        state
      end)

      render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})
      state = :sys.get_state(ctx.view.pid).socket.assigns
      assert state.authentication_pending
      assert state.chat == nil
      assert state.requested_conversation_id == "conversation-1"
      assert Process.read_timer(old.timer) == false
      assert Process.info(ctx.view.pid, :monitors) == initial_monitors
      assert Registry.keys(WebWidget.PubSub, ctx.view.pid) == []
      render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
      refute_receive {:shared_request, %{content: "blocked"}, _, _}

      :sys.replace_state(ctx.view.pid, fn state ->
        Process.delete(:chat_host_failure)
        state
      end)
    end
  end

  test "failed restoration never substitutes a conversation and releases resources", ctx do
    for requested <- ["foreign", "deleted", "unauthorized", "history-failure"] do
      conn =
        put_connect_params(ctx.conn, %{
          "identity_token" => "expired",
          "conversation_id" => requested
        })

      {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
      {:monitors, before} = Process.info(view.pid, :monitors)
      render_event(view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})

      assert_receive {:shared_request, %{type: :conversation_init, conversation_id: ^requested},
                      context, _}

      if requested == "history-failure" do
        assert_receive {:shared_request,
                        %{type: :conversation_history, conversation_id: ^requested}, _, _}
      else
        refute_receive {:shared_request, %{type: :conversation_history}, _, _}
      end

      refute has_element?(view, "#web-widget")
      render_event(view, "widget.submit", %{text: "blocked"}, %{ok: false})
      refute_receive {:shared_request, %{content: _}, _, _}
      assert :sys.get_state(view.pid).socket.assigns.chat == nil
      assert {:monitors, ^before} = Process.info(view.pid, :monitors)

      refute Enum.any?(
               Registry.lookup(WebWidget.PubSub, ChatHost.delivery(context).topic),
               fn {pid, _} ->
                 pid == view.pid
               end
             )

      refute Enum.any?(
               Registry.keys(WebWidget.PubSub, view.pid),
               &String.starts_with?(&1, "web_widget:")
             )
    end
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

  test "new pages bind the same host recipient and old terminals reach both tabs", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, refreshed, _} = live(conn, "/widget/#{ctx.id}")
    first = :sys.get_state(ctx.view.pid).socket.assigns.chat
    second = :sys.get_state(refreshed.pid).socket.assigns.chat
    refute first.session.page_id == second.session.page_id
    assert first.session.topic == second.session.topic
    assert second.session.delivery_binding == context.delivery
    refute render(refreshed) =~ second.session.topic
    refute render(refreshed) =~ "delivery_binding"

    terminal =
      ChatHost.response(request, :message_complete, "conversation-1", %{
        body: "Old request finished"
      })

    ChatHost.publish(context, terminal)
    assert render(refreshed) =~ "Old request finished"
    assert render(ctx.view) =~ "Old request finished"
    ChatHost.publish(context, %{terminal | type: :message_edit, payload: %{body: "LATE"}})
    ChatHost.publish(context, terminal)
    messages = :sys.get_state(refreshed.pid).socket.assigns.chat.state.messages
    assert Enum.count(messages, &(&1.id == terminal.message_id)) == 1
    refute render(refreshed) =~ "LATE"
  end

  test "missing or invalid private binding fails closed and releases resources", ctx do
    for failure <- [:missing, :invalid, :unsubscribable, :events, :version] do
      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_binding, failure)
        state
      end)

      render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})
      assert :sys.get_state(ctx.view.pid).socket.assigns.chat == nil
      assert Registry.keys(WebWidget.PubSub, ctx.view.pid) == []
      render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
      refute_receive {:shared_request, %{content: "blocked"}, _, _}
    end
  end

  test "a changed host binding cannot replace an initialized session during selection", ctx do
    init(ctx)
    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_binding, :changed)
      state
    end)

    render_event(ctx.view, "widget.context.update", %{conversation_id: "conversation-1"}, %{
      ok: false
    })

    assert :sys.get_state(ctx.view.pid).socket.assigns.chat == before
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
  end

  test "recovered processing is indication only and a missed-create edit binds the stream", ctx do
    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_processing, :active)
      state
    end)

    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert chat.state.typing
    assert length(chat.state.messages) == 2
    assert chat.pending_submission == nil
    assert chat.streams == %{}

    response =
      ChatHost.response(%{request_id: "another-tab"}, :message_edit, "conversation-1", %{
        body: "Full snapshot"
      })

    ChatHost.publish(context, response)
    assert render(ctx.view) =~ "Full snapshot"
    ChatHost.publish(context, %{response | type: :message_complete, payload: %{body: "Finished"}})
    assert render(ctx.view) =~ "Finished"
    refute :sys.get_state(ctx.view.pid).socket.assigns.chat.state.typing
  end

  test "persisted assistant references deduplicate history and late live snapshots", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    response =
      ChatHost.response(%{request_id: "old-request"}, :message_complete, "conversation-1", %{
        body: "Saved answer",
        assistant_message_id: "persisted-assistant",
        user_message_id: "persisted-user"
      })

    ChatHost.publish(context, response)

    ChatHost.publish(context, %{
      response
      | type: :message_create,
        payload: %{body: "STALE", assistant_message_id: "persisted-assistant"}
    })

    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert Enum.count(chat.state.messages, &(&1.role == "assistant")) == 1
    refute render(ctx.view) =~ "STALE"
  end

  test "subscribed history bootstrap reconciles queued old snapshots without duplicate rows",
       ctx do
    create =
      ChatHost.response(%{request_id: "previous-page"}, :message_create, "conversation-1", %{
        body: "STALE",
        assistant_message_id: "persisted-assistant",
        user_message_id: "persisted-user"
      })

    terminal = %{
      create
      | type: :message_complete,
        payload: %{
          body: "Saved answer",
          assistant_message_id: "persisted-assistant",
          user_message_id: "persisted-user"
        }
    }

    live_terminal = %{
      terminal
      | request_id: "another-request",
        message_id: "another-answer",
        payload: %{body: "Newer terminal"}
    }

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_processing, :active)
      Process.put(:chat_host_history_events, [create, terminal, live_terminal])
      state
    end)

    init(ctx, %{conversation_id: "conversation-1"})
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert Enum.count(chat.state.messages, &(&1.id == "persisted-assistant")) == 1

    assert Enum.any?(
             chat.state.messages,
             &(&1.content == "Newer terminal" and &1.status == "complete")
           )

    refute Enum.any?(chat.state.messages, &(&1.content == "STALE"))
    refute chat.state.typing
  end

  test "persisted references arriving after create collapse history/live duplicates", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    create =
      ChatHost.response(%{request_id: "old"}, :message_create, "conversation-1", %{body: ""})

    ChatHost.publish(context, create)
    _ = render(ctx.view)

    terminal = %{
      create
      | type: :message_complete,
        payload: %{
          body: "Saved answer",
          assistant_message_id: "persisted-assistant",
          user_message_id: "persisted-user"
        }
    }

    ChatHost.publish(context, terminal)
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert Enum.count(chat.state.messages, &(&1.role == "assistant")) == 1
    assert Enum.count(chat.state.messages, &(&1.role == "user")) == 1
    assert chat.streams[create.message_id].status == :terminal
    ChatHost.publish(context, %{terminal | request_id: "wrong", payload: %{body: "WRONG"}})
    refute render(ctx.view) =~ "WRONG"
  end

  test "inactive typing clears recovery progress; first failed terminal is safe", ctx do
    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_processing, :active)
      state
    end)

    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}
    typing = ChatHost.response(%{request_id: "old"}, :typing, "conversation-1", %{active: false})
    ChatHost.publish(context, typing)
    refute :sys.get_state(ctx.view.pid).socket.assigns.chat.state.typing

    failed =
      ChatHost.response(%{request_id: "other-tab"}, :message_failed, "conversation-1", %{
        body: "Public recovery",
        error: "PRIVATE_TRACE"
      })

    ChatHost.publish(context, failed)
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat

    assert Enum.any?(
             chat.state.messages,
             &(&1.id == failed.message_id and &1.status == "failed" and
                 &1.error == "Public recovery")
           )

    refute render(ctx.view) =~ "PRIVATE_TRACE"
  end

  test "unknown processing does not invent an assistant or a submission spinner", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert chat.streams == %{}
    assert length(chat.state.messages) == 2
    refute chat.state.typing
    refute chat.blocked
    assert chat.pending_submission == nil
  end

  test "other-tab receipts and errors cannot settle or block local submissions", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.chat.pending_submission, "local-request")
    end)

    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    for type <- [:status, :conversation_created, :error] do
      response =
        ChatHost.response(%{request_id: "another-tab"}, type, "conversation-1", %{
          accepted: true,
          created: false,
          code: :timeout,
          outcome: :unknown
        })

      send(
        ctx.view.pid,
        {:web_response, if(type == :error, do: "response.error", else: "response.message.create"),
         response}
      )
    end

    assert :sys.get_state(ctx.view.pid).socket.assigns.chat == before
    assert before.pending_submission == "local-request"

    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.chat.pending_submission, nil)
    end)

    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: true})
    assert_receive {:shared_request, %{content: "no answer"}, ^context, _}
  end

  test "revocation rejects old-request events on the stable recipient before broadcast cleanup",
       ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}
    now = System.system_time(:second)

    assert {:ok, _, true} =
             BindingStore.revoke_user("parent", ctx.id, "visitor", Ecto.UUID.generate(), now, now)

    terminal =
      ChatHost.response(%{request_id: "previous-page"}, :message_complete, "conversation-1", %{
        body: "REVOKED ANSWER"
      })

    ChatHost.publish(context, terminal)
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    refute render(ctx.view) =~ "REVOKED ANSWER"
  end

  test "rejects absent proof, claimed-user mismatch and foreign resume", ctx do
    render_event(ctx.view, "widget.context", %{user_id: "visitor"}, %{ok: false})

    render_event(
      ctx.view,
      "widget.context",
      %{identity_token: token(ctx), user_id: "attacker"},
      %{ok: false}
    )

    refute has_element?(ctx.view, "#web-widget")
    init(ctx)
    render_event(ctx.view, "widget.context.update", %{conversation_id: "foreign"}, %{ok: false})
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
  end

  test "identity and parent conversation context remain separate",
       ctx do
    proof = token(ctx)

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

    render_event(ctx.view, "widget.context.update", %{prompt_context: "Parent context"}, %{
      ok: true
    })

    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})

    assert_receive {:shared_request,
                    %{content: "instant", prompt_context: "Parent context", conversation_id: nil},
                    %{sender_id: "visitor"}, _}
  end

  test "resume loads canonical IDs and untimestamped history before sending", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history, params: %{limit: 50}}, _, _}
    assert render(ctx.view) =~ "Saved answer"
    assert render(ctx.view) =~ "persisted-assistant"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
  end

  test "a restored conversation applies an authorized old-request terminal directly", ctx do
    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, view, _} = live(conn, "/widget/#{ctx.id}")
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    terminal =
      ChatHost.response(%{request_id: "resumed-request"}, :message_complete, "conversation-1", %{
        body: "Authorized terminal body"
      })

    ChatHost.publish(context, %{terminal | conversation_id: "foreign"})
    ChatHost.publish(context, %{terminal | protocol_version: 1})
    ChatHost.publish(context, Map.delete(terminal, :message_id))
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}

    ChatHost.publish(context, terminal)

    assert render(view) =~ "Authorized terminal body"

    assert Enum.any?(
             :sys.get_state(view.pid).socket.assigns.chat.state.messages,
             &(&1.content == "Saved answer")
           )

    ChatHost.publish(context, terminal)
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    refute_receive {:shared_request, %{content: _}, _, _}
  end

  test "an authorized context selection announces the conversation for reconnect", ctx do
    init(ctx)

    render_event(ctx.view, "widget.context.update", %{conversation_id: "conversation-1"}, %{
      ok: true
    })

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}

    assert_push_event(ctx.view, "widget.conversation", %{conversation_id: "conversation-1"})
    assert render(ctx.view) =~ "Saved answer"
  end

  test "restored independent terminals each bind once and reject late edits",
       ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}

    for message <- ["old-one", "old-two"] do
      terminal =
        ChatHost.response(%{request_id: "previous-page"}, :message_complete, "conversation-1", %{
          body: "Recovered answer"
        })

      terminal = %{terminal | message_id: message}
      ChatHost.publish(context, terminal)
      assert render(ctx.view) =~ "Recovered answer"
      ChatHost.publish(context, terminal)
      ChatHost.publish(context, %{terminal | type: :message_edit, payload: %{body: "LATE"}})
      refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    end

    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert map_size(chat.streams) == 2
    assert Enum.count(chat.state.messages, &(&1.content == "Recovered answer")) == 2
    refute Enum.any?(chat.state.messages, &(&1.content == "LATE"))
  end

  test "an old-request terminal never overwrites a current independent live stream", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    terminal =
      ChatHost.response(%{request_id: "previous-page"}, :message_complete, "conversation-1", %{
        body: "Recovered answer"
      })

    ChatHost.publish(context, terminal)
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat

    assert Enum.any?(
             chat.state.messages,
             &(&1.id == "assistant-" <> request.request_id and &1.status == "running")
           )

    assert Enum.any?(chat.state.messages, &(&1.content == "Recovered answer"))
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "Current final"})
    )

    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    assert Enum.any?(chat.state.messages, &(&1.content == "Current final"))
    assert Enum.any?(chat.state.messages, &(&1.content == "Saved answer"))
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
    render_event(ctx.view, "widget.submit", %{text: "second"}, %{ok: true})
    assert_receive {:shared_request, %{content: "second"}, _, _}

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
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
    render_event(ctx.view, "widget.submit", %{text: "timeout"}, %{ok: false})

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

  test "accepted pre-stream failure preserves the public recovery body and releases submission",
       ctx do
    init(ctx)

    body =
      "Personal credentials are required. [Open People portal](https://people.example.test/credentials)."

    text = "pre-stream failure: " <> body
    render_event(ctx.view, "widget.submit", %{text: text}, %{ok: true})
    assert_receive {:shared_request, %{content: ^text} = request, _, _}

    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert MapSet.member?(chat.accepted_requests, request.request_id)
    assert chat.pending_submission == nil
    refute chat.blocked
    refute chat.state.typing

    assert [%{role: "user"}, %{role: "assistant", content: "", status: "failed", error: ^body}] =
             chat.state.messages

    refute render(ctx.view) =~ "PRIVATE_TRACE"
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, _, _}
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

    refute_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "another-visitor"},
                    _}

    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, %{sender_id: "visitor"}, _}
  end

  test "backend disconnect is scoped, idempotent and terminal for the active widget", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}

    other_conn =
      put_connect_params(ctx.conn, %{"identity_token" => token(ctx, %{user_id: "other"})})

    {:ok, other, _} = live(other_conn, "/widget/#{ctx.id}")
    assert_receive {:shared_request, %{type: :conversation_init}, %{sender_id: "other"}, _}

    {:ok, control} =
      ControlProof.sign(ctx.key, ctx.id, "visitor",
        issuer: "parent",
        audience: "widget:control"
      )

    endpoint = "/widget-api/#{ctx.id}/disconnect"

    request = fn proof, user ->
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> proof)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post(endpoint, Jason.encode!(%{user_id: user}))
    end

    assert %{status: 401} = request.(token(ctx), "visitor")
    assert %{status: 401} = request.(control, "another-visitor")
    assert %{status: 401} = request.(control <> "x", "visitor")
    assert has_element?(ctx.view, "#web-widget")

    assert %{status: 401} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> control)
             |> post(endpoint, %{user_id: "visitor"})

    assert %{status: 401} =
             Phoenix.ConnTest.build_conn()
             |> Plug.Conn.put_req_header("authorization", "Bearer " <> control)
             |> Plug.Conn.put_req_header("content-type", "application/json")
             |> post("/widget-api/#{ctx.id + 1}/disconnect", Jason.encode!(%{user_id: "visitor"}))

    assert %{status: 200, resp_body: body} = request.(control, "visitor")
    cutoff = Jason.decode!(body)["cutoff"]
    assert is_integer(cutoff)
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
    assert %{status: 200, resp_body: retry_body} = request.(control, "visitor")
    assert Jason.decode!(retry_body)["cutoff"] == cutoff

    [_, payload, _] = String.split(control, ".")

    conflicting_claims =
      payload
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.put("user_id", "other")

    {_metadata, conflicting_proof} =
      ctx.key
      |> JOSE.JWK.from_oct()
      |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "JWT"}, conflicting_claims)
      |> JOSE.JWS.compact()

    assert %{status: 401} = request.(conflicting_proof, "other")
    render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{ok: false})
    render_event(other, "widget.submit", %{text: "instant"}, %{ok: true})
    assert_receive {:shared_request, %{content: "instant"}, %{sender_id: "other"}, _}
  end

  test "a send after cutoff fails closed before the revocation broadcast", ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}
    now = System.system_time(:second)

    assert {:ok, _, true} =
             BindingStore.revoke_user("parent", ctx.id, "visitor", Ecto.UUID.generate(), now, now)

    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "backend_revoked"})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  test "receipt without assistant ID settles submission even when no answer follows", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: true})
    assert_receive {:shared_request, %{content: "no answer"}, _, _}
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert chat.pending_submission == nil
    assert chat.state.pending_reply == nil
    assert chat.streams == %{}
    assert [%{role: "user", content: "no answer"}] = chat.state.messages
    refute chat.state.typing
    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: true})

    assert_receive {:shared_request, %{conversation_id: "conversation-1", content: "no answer"},
                    _, _}
  end

  test "independent streams survive later submissions and reject late or foreign events", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = first, context, _}
    render_event(ctx.view, "widget.submit", %{text: "second"}, %{ok: true})
    assert_receive {:shared_request, %{content: "second"} = second, _, _}
    one = ChatHost.response(first, :message_edit, "conversation-1", %{body: "First snapshot"})
    two = ChatHost.response(second, :message_edit, "conversation-1", %{body: "Second snapshot"})
    ChatHost.publish(context, one)
    ChatHost.publish(context, two)
    messages = :sys.get_state(ctx.view.pid).socket.assigns.chat.state.messages
    assert Enum.any?(messages, &(&1.content == "First snapshot"))
    assert Enum.any?(messages, &(&1.content == "Second snapshot"))

    for forged <- [
          %{one | conversation_id: "foreign", payload: %{body: "INJECTED"}},
          %{one | request_id: second.request_id, payload: %{body: "INJECTED"}},
          %{one | protocol_version: 1, payload: %{body: "INJECTED"}}
        ] do
      ChatHost.publish(context, forged)
    end

    refute render(ctx.view) =~ "INJECTED"

    ChatHost.publish(context, %{one | type: :message_complete, payload: %{body: "First final"}})

    for type <- [:message_edit, :message_complete, :message_failed] do
      ChatHost.publish(context, %{one | type: type, payload: %{body: "LATE"}})
    end

    ChatHost.publish(context, %{two | payload: %{body: "Second continues"}})
    messages = :sys.get_state(ctx.view.pid).socket.assigns.chat.state.messages
    assert Enum.any?(messages, &(&1.content == "First final" and &1.status == "complete"))
    refute Enum.any?(messages, &(&1.content == "LATE"))
    assert render(ctx.view) =~ "Second continues"
    refute render(ctx.view) =~ "LATE"

    extra = %{
      one
      | type: :message_create,
        message_id: "extra-stream",
        payload: %{body: "Independent"}
    }

    ChatHost.publish(context, extra)

    ChatHost.publish(context, %{
      extra
      | type: :message_complete,
        payload: %{body: "Independent final"}
    })

    assert render(ctx.view) =~ "Independent final"
  end

  test "submission errors never fail an already accepted assistant stream", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    render_event(ctx.view, "widget.submit", %{text: "timeout"}, %{ok: false})
    assert_receive {:shared_request, %{content: "timeout"}, _, _}

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{body: "Still finishes"})
    )

    assert render(ctx.view) =~ "Still finishes"
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert List.last(chat.state.messages).status == "complete"
    assert chat.blocked
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  test "known submission rejection settles only that request and permits another send", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}
    render_event(ctx.view, "widget.submit", %{text: "rejected"}, %{ok: false})
    assert_receive {:shared_request, %{content: "rejected"}, _, _}
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    refute chat.blocked
    assert chat.pending_submission == nil
    assert List.last(chat.state.messages).status == "running"

    ChatHost.publish(
      context,
      ChatHost.response(request, :error, "conversation-1", %{code: :timeout, outcome: :unknown})
    )

    refute :sys.get_state(ctx.view.pid).socket.assigns.chat.blocked

    ChatHost.publish(
      context,
      ChatHost.response(request, :message_complete, "conversation-1", %{
        body: "Accepted stream finishes"
      })
    )

    assert render(ctx.view) =~ "Accepted stream finishes"
    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: true})
  end

  test "unsupported receipt version is rejected explicitly without automatic retry", ctx do
    init(ctx)

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_protocol_version, 1)
      state
    end)

    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: false})
    assert render(ctx.view) =~ "Unsupported host protocol version"
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert chat.conversation_id == nil
    assert chat.accepted_requests == MapSet.new()
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}
  end

  test "typing from another submission or a finished stream cannot clear current progress", ctx do
    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = first, context, _}
    render_event(ctx.view, "widget.submit", %{text: "second"}, %{ok: true})
    assert_receive {:shared_request, %{content: "second"} = second, _, _}

    ChatHost.publish(
      context,
      ChatHost.response(first, :typing, "conversation-1", %{active: false})
    )

    assert :sys.get_state(ctx.view.pid).socket.assigns.chat.state.typing

    ChatHost.publish(
      context,
      ChatHost.response(first, :message_complete, "conversation-1", %{body: "Done"})
    )

    ChatHost.publish(
      context,
      ChatHost.response(first, :typing, "conversation-1", %{active: true})
    )

    ChatHost.publish(
      context,
      ChatHost.response(second, :typing, "conversation-1", %{active: false})
    )

    refute :sys.get_state(ctx.view.pid).socket.assigns.chat.state.typing
  end

  test "historical duplicate terminals preserve another running stream under the same request",
       ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    render_event(ctx.view, "widget.submit", %{text: "stream"}, %{ok: true})
    assert_receive {:shared_request, %{content: "stream"} = request, context, _}

    historical =
      ChatHost.response(request, :message_complete, "conversation-1", %{
        body: "Saved answer",
        assistant_message_id: "persisted-assistant"
      })

    historical = %{historical | message_id: "historical-transport"}
    ChatHost.publish(context, historical)
    ChatHost.publish(context, historical)
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert chat.state.typing
    assert chat.streams["assistant-" <> request.request_id].status == :running
    assert Enum.count(chat.state.messages, &(&1.content == "Saved answer")) == 1
  end

  test "context update accepts an explicit null prompt when selecting a conversation", ctx do
    init(ctx)
    conversation = "5eee64ff-5ed9-4940-90a5-df15ebe70855"

    render_hook(ctx.view, "widget.context.update", %{
      conversation_id: conversation,
      prompt_context: nil
    })

    assert_reply(ctx.view, %{ok: true, conversation_id: ^conversation})

    assert_receive {:shared_request, %{type: :conversation_init, conversation_id: ^conversation},
                    _, _}

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: ^conversation}, _, _}
  end

  test "context errors distinguish invalid fields, pending submissions and expired sessions",
       ctx do
    init(ctx)
    assert_receive {:shared_request, %{type: :conversation_init}, _, _}
    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    assert_context_error(
      ctx.view,
      %{conversation_id: 123, prompt_context: nil},
      "invalid_context_fields"
    )

    assert_context_error(
      ctx.view,
      %{conversation_id: "conversation-1", profile: "PRIVATE"},
      "invalid_context_fields"
    )

    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.pending_reply, %{request_id: "local"})
    end)

    assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, "submission_pending")

    :sys.replace_state(ctx.view.pid, fn state ->
      state = put_in(state.socket.assigns.pending_reply, nil)
      put_in(state.socket.assigns.chat.pending_submission, "local")
    end)

    assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, "submission_pending")

    :sys.replace_state(ctx.view.pid, fn state ->
      state = put_in(state.socket.assigns.chat, before)
      put_in(state.socket.assigns.chat.session.expires_at, 0)
    end)

    assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, "session_unauthorized")
    refute_receive {:shared_request, _, _, _}
  end

  test "context errors hide conversation ownership and preserve the selected state", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    replies =
      for conversation <- ["foreign", "deleted", "unauthorized"] do
        assert_context_error(
          ctx.view,
          %{conversation_id: conversation},
          "conversation_unavailable"
        )
      end

    assert Enum.uniq(replies) |> length() == 1
    assert :sys.get_state(ctx.view.pid).socket.assigns.chat == before
    assert_context_error(ctx.view, %{prompt_context: nil}, "conversation_required")
  end

  test "context errors identify initialization and history availability separately", ctx do
    init(ctx)

    for {operation, reason} <- [
          {:conversation_init, "host_unavailable"},
          {:conversation_history, "history_unavailable"}
        ] do
      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_failure, operation)
        state
      end)

      assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, reason)
    end
  end

  test "context errors distinguish missing, invalid and changed delivery bindings", ctx do
    init(ctx)
    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    for {failure, reason} <- [
          {:missing, "delivery_binding_missing"},
          {:invalid, "invalid_delivery_binding"},
          {:changed, "delivery_binding_changed"}
        ] do
      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_binding, failure)
        state
      end)

      assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, reason)
      assert :sys.get_state(ctx.view.pid).socket.assigns.chat == before
      refute_receive {:shared_request, %{type: :conversation_history}, _, _}
    end
  end

  test "context errors expose safe protocol categories, never raw host details", ctx do
    init(ctx)

    for {operation, transform, reason} <- [
          {:conversation_init, fn reply -> put_in(reply.response.protocol_version, 1) end,
           "unsupported_protocol_version"},
          {:conversation_init, fn reply -> put_in(reply.response.request_id, "wrong-request") end,
           "invalid_host_response"},
          {:conversation_init,
           fn _ -> {:error, {:PRIVATE_TRACE, "person-id", "web_widget:recipient:private"}} end,
           "host_initialization_rejected"},
          {:conversation_init,
           fn reply ->
             %{
               reply.response
               | type: :error,
                 payload: %{code: :missing_delivery_descriptor, error: "PRIVATE_TRACE"}
             }
           end, "delivery_binding_missing"},
          {:conversation_history, fn reply -> %{reply | request_id: "wrong-request"} end,
           "invalid_history_response"},
          {:conversation_history,
           fn reply -> %{reply | payload: %{messages: "PRIVATE_TRACE"}} end,
           "invalid_history_response"},
          {:conversation_history,
           fn reply ->
             %{
               reply
               | payload: %{
                   messages: [
                     %{
                       message_id: %{private: "PRIVATE_TRACE"},
                       role: "assistant",
                       content: "Answer"
                     }
                   ]
                 }
             }
           end, "invalid_history_response"}
        ] do
      :sys.replace_state(ctx.view.pid, fn state ->
        Process.put(:chat_host_transform, fn request, reply ->
          if request[:type] == operation, do: transform.(reply), else: reply
        end)

        state
      end)

      reply = assert_context_error(ctx.view, %{conversation_id: "conversation-1"}, reason)
      refute inspect(reply) =~ "PRIVATE_TRACE"
      refute inspect(reply) =~ "person-id"
      refute inspect(reply) =~ "web_widget:recipient:"
    end
  end

  test "accepted canonical user reaches both tabs once and acknowledges only its origin", ctx do
    init(ctx, %{conversation_id: "conversation-1"})

    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, other, _} = live(conn, "/widget/#{ctx.id}")

    foreign_conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx, %{user_id: "other-person"}),
        "conversation_id" => "conversation-1"
      })

    {:ok, foreign, _} = live(foreign_conn, "/widget/#{ctx.id}")

    :sys.replace_state(other.pid, fn state ->
      put_in(state.socket.assigns.chat.pending_submission, "other-local-request")
    end)

    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "sender-draft"})
    assert_reply(ctx.view, %{ok: true})

    assert_push_event(ctx.view, "widget.submission.ack", %{
      submission_id: "sender-draft",
      message_id: saved
    })

    first = :sys.get_state(ctx.view.pid).socket.assigns.chat
    second = :sys.get_state(other.pid).socket.assigns.chat
    assert Enum.count(first.state.messages, &(&1.id == saved and &1.content == "no answer")) == 1
    assert Enum.count(second.state.messages, &(&1.id == saved and &1.content == "no answer")) == 1
    assert second.pending_submission == "other-local-request"
    assert second.acknowledged_submission == nil
    refute first.state.typing
    assert first.streams == %{}

    refute Enum.any?(
             :sys.get_state(foreign.pid).socket.assigns.chat.state.messages,
             &(&1.id == saved)
           )
  end

  test "fast assistant is reordered behind its late canonical user without duplicates", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}
    request = %{request_id: "remote-request", content: "Saved input"}
    payload = ChatHost.acceptance(request, false)

    assistant =
      ChatHost.response(request, :message_complete, "conversation-1", %{
        body: "Fast answer",
        user_message_id: payload.user_message.message_id
      })

    ChatHost.publish(context, assistant)
    _ = render(ctx.view)
    user = ChatHost.response(request, :user_message, "conversation-1", payload)
    ChatHost.publish(context, user)
    ChatHost.publish(context, user)
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert Enum.map(Enum.take(chat.state.messages, -2), & &1.role) == ["user", "assistant"]
    assert Enum.count(chat.state.messages, &(&1.id == payload.user_message.message_id)) == 1
    assert chat.streams[assistant.message_id].status == :terminal
  end

  test "matching broadcast reconciles unknown first acknowledgement but another tab cannot select it",
       ctx do
    init(ctx)
    conn = put_connect_params(ctx.conn, %{"identity_token" => token(ctx)})
    {:ok, unselected, _} = live(conn, "/widget/#{ctx.id}")

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_transform, fn request, reply ->
        if Map.has_key?(request, :content),
          do:
            ChatHost.response(
              request,
              :error,
              reply |> elem(1) |> Map.fetch!(:conversation_id),
              %{code: :acknowledgement_unavailable, outcome: :unknown}
            ),
          else: reply
      end)

      state
    end)

    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "uncertain-draft"})

    assert_reply(ctx.view, %{
      ok: false,
      outcome: :unknown,
      recovery_conversation_id: "conversation-1"
    })

    assert_push_event(ctx.view, "widget.submission.ack", %{submission_id: "uncertain-draft"})
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    refute chat.blocked
    assert chat.conversation_id == "conversation-1"
    assert [%{role: "user", content: "no answer"}] = chat.state.messages
    assert :sys.get_state(unselected.pid).socket.assigns.chat.conversation_id == nil
    assert :sys.get_state(unselected.pid).socket.assigns.chat.state.messages == []
  end

  test "missing saved acknowledgement retains a known conversation only as an authorized recovery hint",
       ctx do
    init(ctx)

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_suppress_user, true)

      Process.put(:chat_host_transform, fn request, reply ->
        if Map.has_key?(request, :content),
          do:
            ChatHost.response(request, :error, "conversation-1", %{
              code: :acknowledgement_unavailable,
              outcome: :unknown
            }),
          else: reply
      end)

      state
    end)

    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "unknown"})

    assert_reply(ctx.view, %{
      ok: false,
      outcome: :unknown,
      recovery_conversation_id: "conversation-1"
    })

    state = :sys.get_state(ctx.view.pid).socket.assigns
    assert state.chat.conversation_id == nil
    assert state.chat.blocked
    assert state.chat.state.messages == []
    assert state.requested_conversation_id == "conversation-1"
    render_event(ctx.view, "widget.submit", %{text: "blocked"}, %{ok: false})
    refute_receive {:shared_request, %{content: "blocked"}, _, _}

    render_event(ctx.view, "widget.context.update", %{conversation_id: "conversation-1"}, %{
      ok: true
    })

    assert_receive {:shared_request,
                    %{type: :conversation_history, conversation_id: "conversation-1"}, _, _}
  end

  test "legacy trusted descriptors accept the canonical direct receipt without a user event mapping",
       ctx do
    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_binding, :legacy)
      state
    end)

    init(ctx)
    render_event(ctx.view, "widget.submit", %{text: "no answer"}, %{ok: true})
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat
    refute Map.has_key?(chat.session.delivery_binding.events, :user_message)
    assert [%{role: "user", content: "no answer", position: position}] = chat.state.messages
    assert position > 0
    assert chat.pending_submission == nil
  end

  test "user events retain authentication, conversation, protocol and message namespace checks",
       ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    assert_receive {:shared_request, %{type: :conversation_history}, context, _}
    request = %{request_id: "remote", content: "PRIVATE USER"}

    response =
      ChatHost.response(
        request,
        :user_message,
        "conversation-1",
        ChatHost.acceptance(request, false)
      )

    before = :sys.get_state(ctx.view.pid).socket.assigns.chat

    for invalid <- [
          %{response | conversation_id: "foreign"},
          %{response | protocol_version: 1},
          %{response | message_id: "assistant"},
          put_in(response.payload.user_message.role, "external")
        ] do
      ChatHost.publish(context, invalid)
    end

    send(ctx.view.pid, {:web_response, "response.message.create", response})

    collision = %{
      ChatHost.response(request, :message_complete, "conversation-1", %{
        body: "COLLISION",
        assistant_message_id: "persisted-assistant"
      })
      | message_id: "persisted-user"
    }

    ChatHost.publish(context, collision)
    assert :sys.get_state(ctx.view.pid).socket.assigns.chat == before

    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.chat.local_submissions, %{
        "remote" => %{conversation_id: "foreign", status: :unknown, submission_id: "keep-draft"}
      })
    end)

    scoped = :sys.get_state(ctx.view.pid).socket.assigns.chat
    ChatHost.publish(context, response)
    assert :sys.get_state(ctx.view.pid).socket.assigns.chat == scoped

    :sys.replace_state(ctx.view.pid, fn state ->
      put_in(state.socket.assigns.chat.session.expires_at, 0)
    end)

    ChatHost.publish(context, response)
    assert_push_event(ctx.view, "widget.authentication.required", %{reason: "expired"})
    refute render(ctx.view) =~ "PRIVATE USER"
  end

  test "fast first answer waits for matching saved-user recovery after an unknown callback",
       ctx do
    init(ctx)
    parent = self()

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_suppress_user, true)

      Process.put(:chat_host_transform, fn request, reply ->
        if Map.has_key?(request, :content) do
          {:ok, receipt} = reply
          send(parent, {:saved_receipt, receipt})

          ChatHost.response(request, :error, receipt.conversation_id, %{
            code: :acknowledgement_unavailable,
            outcome: :unknown
          })
        else
          reply
        end
      end)

      state
    end)

    render_hook(ctx.view, "widget.submit", %{text: "instant", submission_id: "fast-unknown"})
    assert_reply(ctx.view, %{ok: false, outcome: :unknown})
    assert_receive {:shared_request, %{content: "instant"}, context, _}
    assert_receive {:saved_receipt, receipt}
    before = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert before.conversation_id == nil
    assert before.state.messages == []
    assert before.deferred_events != []

    late =
      ChatHost.response(
        %{request_id: receipt.request_id},
        :message_edit,
        receipt.conversation_id,
        %{body: "LATE"}
      )

    for _ <- 1..140, do: ChatHost.publish(context, late)
    ChatHost.publish(context, %{receipt | type: :user_message})
    assert_push_event(ctx.view, "widget.submission.ack", %{submission_id: "fast-unknown"})
    chat = :sys.get_state(ctx.view.pid).socket.assigns.chat

    assert [
             %{role: "user", content: "instant"},
             %{role: "assistant", content: "Immediate answer", status: "complete"}
           ] = chat.state.messages

    assert chat.deferred_events == []
    assert has_element?(ctx.view, "#widget-state[data-mode=conversation]")
  end

  test "two sending tabs converge canonical inputs while retaining independent acknowledgement ownership",
       ctx do
    init(ctx, %{conversation_id: "conversation-1"})

    conn =
      put_connect_params(ctx.conn, %{
        "identity_token" => token(ctx),
        "conversation_id" => "conversation-1"
      })

    {:ok, other, _} = live(conn, "/widget/#{ctx.id}")
    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "first-draft"})
    assert_reply(ctx.view, %{ok: true})
    assert_receive {:shared_request, %{content: "no answer"} = first_request, _, _}
    refute Map.has_key?(first_request, :submission_id)
    render_hook(other, "widget.submit", %{text: "no answer", submission_id: "second-draft"})
    assert_reply(other, %{ok: true})
    assert_receive {:shared_request, %{content: "no answer"} = second_request, _, _}
    first = :sys.get_state(ctx.view.pid).socket.assigns.chat
    second = :sys.get_state(other.pid).socket.assigns.chat

    inputs = fn chat ->
      chat.state.messages
      |> Enum.filter(&(&1.role == "user" and &1.content == "no answer"))
      |> Enum.map(&{&1.id, &1.position})
    end

    assert length(inputs.(first)) == 2
    assert inputs.(first) == inputs.(second)
    assert first.acknowledged_submission.submission_id == "first-draft"
    assert second.acknowledged_submission.submission_id == "second-draft"
    assert MapSet.member?(first.accepted_requests, first_request.request_id)
    refute MapSet.member?(first.accepted_requests, second_request.request_id)
    assert MapSet.member?(second.accepted_requests, second_request.request_id)
    refute MapSet.member?(second.accepted_requests, first_request.request_id)
  end

  test "a late saved acknowledgement cannot settle a newer uncertain local submission", ctx do
    init(ctx, %{conversation_id: "conversation-1"})
    parent = self()

    :sys.replace_state(ctx.view.pid, fn state ->
      Process.put(:chat_host_suppress_user, true)

      Process.put(:chat_host_transform, fn request, reply ->
        if Map.has_key?(request, :content) do
          {:ok, receipt} = reply
          send(parent, {:saved_ack, receipt})

          ChatHost.response(request, :error, receipt.conversation_id, %{
            code: :acknowledgement_unavailable,
            outcome: :unknown
          })
        else
          reply
        end
      end)

      state
    end)

    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "old"})
    assert_reply(ctx.view, %{ok: false, outcome: :unknown})
    assert_receive {:saved_ack, first}
    assert_receive {:shared_request, %{content: "no answer"}, context, _}

    render_event(ctx.view, "widget.context.update", %{conversation_id: "conversation-1"}, %{
      ok: true
    })

    render_hook(ctx.view, "widget.submit", %{text: "no answer", submission_id: "new"})
    assert_reply(ctx.view, %{ok: false, outcome: :unknown})
    assert_receive {:saved_ack, second}
    ChatHost.publish(context, %{first | type: :user_message})
    old = :sys.get_state(ctx.view.pid).socket.assigns.chat
    assert old.blocked
    assert old.acknowledged_submission == nil
    ChatHost.publish(context, %{second | type: :user_message})
    assert_push_event(ctx.view, "widget.submission.ack", %{submission_id: "new"})
    refute :sys.get_state(ctx.view.pid).socket.assigns.chat.blocked
  end

  defp assert_context_error(view, params, reason) do
    render_hook(view, "widget.context.update", params)
    assert_reply(view, %{ok: false, reason: ^reason, error: message} = reply)
    assert is_binary(message) and byte_size(message) > 0
    reply
  end

  defp init(ctx, params \\ %{}) do
    render_event(ctx.view, "widget.context", %{identity_token: token(ctx)}, %{
      ok: true
    })

    if map_size(params) > 0,
      do: render_event(ctx.view, "widget.context.update", params, %{ok: true})
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
