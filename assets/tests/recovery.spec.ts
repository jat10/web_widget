import { expect, test, type Page, type APIRequestContext } from "@playwright/test";

const control = "http://127.0.0.1:4021/sessions";
async function session(request: APIRequestContext, config: Record<string, unknown> = {}) {
  const id = crypto.randomUUID();
  expect((await request.post(`${control}/${id}`, { data: config })).ok()).toBe(true);
  return id;
}
async function events(request: APIRequestContext, id: string) {
  const response = await request.get(`${control}/${id}`);
  expect(response.ok()).toBe(true);
  return (await response.json()).events as { type: string; user_id: string; conversation_id: string; message?: { content: string } }[];
}
async function complete(request: APIRequestContext, id: string, fail = false) {
  expect((await request.post(`${control}/${id}/complete`, { data: { fail } })).ok()).toBe(true);
}
async function embed(page: Page, user: string, id = "test-widget", multiple = false) {
  await page.evaluate(({ user, id, multiple }) => {
    const iframe = document.createElement("iframe");
    iframe.id = id;
    iframe.style.cssText = "width:600px;height:700px;border:0;display:inline-block;vertical-align:top";
    iframe.dataset.readyCount = "0";
    window.addEventListener("message", event => {
      if (event.source !== iframe.contentWindow || event.origin !== location.origin) return;
      if (event.data?.type === "zaq.widget.ready") {
        iframe.dataset.readyCount = String(Number(iframe.dataset.readyCount) + 1);
        iframe.contentWindow!.postMessage({
          type: "zaq.widget.init", user_id: user, conversation_id: `conversation-${user}`,
          prompt_context: `Context for ${user}`,
        }, location.origin);
      }
    });
    iframe.src = `/widget/${multiple ? "e2e-multi" : "e2e"}`;
    document.body.append(iframe);
  }, { user, id, multiple });
  const widget = page.frameLocator(`#${id}`);
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();
  return widget;
}

for (const kind of ["none", "status", "reasoning", "tool_call", "tool_result"]) {
  test(`${kind} progress uses tool presentation only for explicit tool steps`, async ({ page, request }) => {
    const id = await session(request, { hold: true, step_kind: kind, partial: "" });
    await page.goto("/widget/missing");
    const widget = await embed(page, id);
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill("A simple question");
    await input.press("Enter");
    const isTool = kind === "tool_call" || kind === "tool_result";
    await expect(widget.locator(".zaq-working")).toHaveText(isTool ? "Working with tools" : "Preparing your answer");
    if (!isTool) {
      await expect(widget.locator(".zaq-activity")).toHaveCount(0);
      await expect(widget.locator(".zaq-response-step")).toHaveCount(0);
    } else {
      const step = widget.locator(`.zaq-response-step[data-kind="${kind}"]`);
      await step.locator("summary").click();
      await expect(step.locator(".zaq-tool-output p")).toHaveText(isTool ? "Waiting for the tool to return a result…" : "Preparing your answer");
      if (!isTool) await expect(widget.getByText("Working with tools", { exact: true })).toHaveCount(0);
    }
    await complete(request, id);
    await expect(widget.locator(".zaq-working")).toHaveCount(0);
    await expect(widget.locator(".zaq-answer-content")).toHaveText("Controlled host reply");
    if (!isTool) await expect(widget.locator(".zaq-activity")).toHaveCount(0);
  });
}

for (const rejection of ["widget.init", "message.create", "conversation.history.request"]) {
  test(`${rejection} rejection preserves the draft and retries without duplicate messages`, async ({ page, request }) => {
    const id = await session(request, {
      reject: rejection,
      history: [{ id: "previous", role: "assistant", content: "Previously saved answer" }],
    });
    await page.goto("/widget/missing");
    const widget = await embed(page, id);
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    const draft = `Retry ${rejection}`;
    await input.fill(draft);
    await input.press("Enter");
    await expect(widget.getByRole("alert")).toContainText(
      rejection === "message.create" ? "Unable to send your message" : "Unable to initialize chat",
    );
    await expect(input).toHaveValue(draft);
    await expect(widget.locator('[data-role="user"]')).toHaveCount(0);
    expect((await events(request, id)).filter(event => event.type === rejection)).toHaveLength(1);
    await widget.getByRole("button", { name: "Send message" }).click();
    await expect(widget.locator(".zaq-answer-content")).toHaveText(["Previously saved answer", "Controlled host reply"]);
    await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText(draft);
    await expect(widget.getByRole("alert")).toHaveCount(0);
    await expect(input).toHaveValue("");
    expect((await events(request, id)).filter(event => event.type === rejection)).toHaveLength(2);
    const state = await (await request.get(`${control}/${id}`)).json();
    expect(state.messages.filter((message: { role: string }) => message.role === "user")).toHaveLength(1);
  });
}

test("two conversations using the same widget ID receive only their own responses", async ({ page, request }) => {
  const firstId = await session(request, { hold: true, answer: "First private answer" });
  const secondId = await session(request, { hold: true, answer: "Second private answer" });
  await page.setViewportSize({ width: 1300, height: 850 });
  await page.goto("/widget/missing");
  const first = await embed(page, firstId, "first");
  const second = await embed(page, secondId, "second");
  for (const [widget, text] of [[first, "First private question"], [second, "Second private question"]] as const) {
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill(text);
    await input.press("Enter");
    await expect(widget.locator(".zaq-answer-content")).toContainText("Partial reply");
  }
  await complete(request, secondId);
  await expect(second.locator(".zaq-answer-content")).toHaveText("Second private answer");
  await expect(first.locator(".zaq-answer-content")).toContainText("Partial reply");
  await expect(first.getByRole("button", { name: "Send message" })).toHaveText("Working…");
  await complete(request, firstId);
  await expect(first.locator(".zaq-answer-content")).toHaveText("First private answer");
  await expect(second.locator(".zaq-answer-content")).toHaveText("Second private answer");
  await expect(first.locator('[data-role="user"] .zaq-user-content')).toHaveText("First private question");
  await expect(second.locator('[data-role="user"] .zaq-user-content')).toHaveText("Second private question");
  for (const id of [firstId, secondId]) {
    const creates = (await events(request, id)).filter(event => event.type === "message.create");
    expect(creates).toHaveLength(1);
    expect(creates[0]).toMatchObject({ user_id: id, conversation_id: `conversation-${id}` });
  }
});

test("reconnect restores host history on the next submission after an interrupted response", async ({ page, request }) => {
  const id = await session(request, { hold: true, answer: "Answer completed while disconnected" });
  await page.goto("/widget/missing");
  const widget = await embed(page, id);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Before disconnect");
  await input.press("Enter");
  await expect(widget.locator(".zaq-answer-content")).toContainText("Partial reply");
  const frame = page.frames().find(frame => frame.url().endsWith("/widget/e2e"))!;
  await frame.evaluate(() => new Promise<void>(resolve => (window as any).liveSocket.disconnect(resolve)));
  await complete(request, id);
  await frame.evaluate(() => (window as any).liveSocket.connect());
  await expect(page.locator("#test-widget")).toHaveAttribute("data-ready-count", "2");
  await expect(input).toBeVisible();
  await input.fill("After reconnect");
  await expect(widget.getByRole("button", { name: "Send message" })).toBeEnabled();
  await input.press("Enter");
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText(["Before disconnect", "After reconnect"]);
  await expect(widget.locator(".zaq-answer-content")).toContainText(["Answer completed while disconnected", "Partial reply"]);
  await complete(request, id);
  await expect(widget.getByRole("button", { name: "Send message" })).toHaveText("Send");
  const recorded = await events(request, id);
  expect(recorded.filter(event => event.type === "widget.init")).toHaveLength(2);
  expect(recorded.filter(event => event.type === "conversation.history.request")).toHaveLength(2);
  expect(recorded.filter(event => event.type === "message.create").map(event => event.message!.content))
    .toEqual(["Before disconnect", "After reconnect"]);
});

for (const fail of [false, true]) {
  test(`conversation controls unlock after response ${fail ? "failure" : "completion"}`, async ({ page, request }) => {
    const id = await session(request, { hold: true });
    await page.goto("/widget/missing");
    const widget = await embed(page, id, "test-widget", true);
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill("Keep this conversation selected");
    await input.press("Enter");
    await expect(widget.locator(".zaq-answer-content")).toContainText("Partial reply");
    const sidebar = widget.getByRole("complementary", { name: "Conversations" });
    const newChat = sidebar.getByRole("button", { name: "New chat", exact: true });
    const other = sidebar.getByRole("button", { name: "Other chat", exact: true });
    await expect(newChat).toBeDisabled();
    await expect(other).toBeDisabled();
    await complete(request, id, fail);
    if (fail) await expect(widget.getByRole("alert")).toContainText("Controlled failure");
    else await expect(widget.locator(".zaq-answer-content")).toHaveText("Controlled host reply");
    await expect(newChat).toBeEnabled();
    await expect(other).toBeEnabled();
    await other.click();
    await expect(other).toHaveAttribute("aria-current", "page");
    await newChat.click();
    await expect(widget.locator('[data-role="user"]')).toHaveCount(0);
    await expect(input).toBeVisible();
  });
}

test("user and host HTML-like content is rendered as text without executing or injecting controls", async ({ page, request }) => {
  const attack = '<img src=x onerror="window.injected=true"><script>window.injected=true</script><button id="injected">Fake action</button>';
  const id = await session(request, { answer: attack });
  await page.goto("/widget/missing");
  const widget = await embed(page, id);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill(attack);
  await input.press("Enter");
  await expect(widget.locator(".zaq-user-content")).toHaveText(attack);
  await expect(widget.locator(".zaq-answer-content")).toHaveText(attack);
  await expect(widget.locator('[data-role] img, [data-role] script, #injected')).toHaveCount(0);
  expect(await input.evaluate(() => (window as any).injected)).toBeUndefined();
});

test("message length limit accepts the boundary and rejects oversized submissions without losing drafts", async ({ page, request }) => {
  const id = await session(request);
  await page.goto("/widget/missing");
  const widget = await embed(page, id);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  const atLimit = "x".repeat(2000);
  await expect(input).toHaveAttribute("maxlength", "2000");
  await input.fill(atLimit);
  await input.press("End");
  await input.pressSequentially("y");
  await expect(input).toHaveValue(atLimit);
  await input.press("Enter");
  await expect(widget.locator(".zaq-user-content")).toHaveText(atLimit);
  await expect(widget.locator(".zaq-answer-content")).toHaveText("Controlled host reply");
  // A modified client can bypass HTML maxlength; server validation must still reject it.
  await input.evaluate(element => element.removeAttribute("maxlength"));
  const oversized = "z".repeat(2001);
  await input.fill(oversized);
  await input.press("Enter");
  await expect(widget.getByRole("alert")).toContainText("Enter a message of 1–2000 characters");
  await expect(input).toHaveValue(oversized);
  await expect(widget.locator('[data-role="user"]')).toHaveCount(1);
  expect((await events(request, id)).filter(event => event.type === "message.create")).toHaveLength(1);
  await input.fill("Corrected draft");
  await input.press("Enter");
  await expect(widget.locator(".zaq-user-content")).toHaveText([atLimit, "Corrected draft"]);
  await expect(widget.getByRole("alert")).toHaveCount(0);
});

test("keyboard navigation reaches send, activity, close and reopen with visible focus", async ({ page, browserName }) => {
  await page.goto("/widget-demo");
  // macOS WebKit uses Option-Tab to include buttons in keyboard navigation.
  const tab = browserName === "webkit" && await page.evaluate(() => navigator.platform.startsWith("Mac"))
    ? "Alt+Tab" : "Tab";
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.focus();
  await input.fill("research");
  await page.keyboard.press(tab);
  const send = widget.getByRole("button", { name: "Send message" });
  await expect(send).toBeFocused();
  await expect(send).toHaveCSS("outline-style", "solid");
  await page.keyboard.press("Enter");
  const activity = widget.locator(".zaq-activity-toggle");
  await expect(activity).toHaveAttribute("aria-expanded", "false");
  await expect(input).toBeFocused();
  // Walk backwards through the rendered controls instead of clicking them.
  for (let i = 0; i < 8 && !(await activity.evaluate(el => el === document.activeElement)); i++) {
    await page.keyboard.press(`Shift+${tab}`);
  }
  await expect(activity).toBeFocused();
  expect(await activity.evaluate(el => el.matches(":focus-visible"))).toBe(true);
  await expect(activity).toHaveCSS("outline-style", "solid");
  await page.keyboard.press("Enter");
  await expect(activity).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Enter");
  const close = widget.getByRole("button", { name: "Close chat", exact: true });
  for (let i = 0; i < 8 && !(await close.evaluate(el => el === document.activeElement)); i++) {
    await page.keyboard.press(`Shift+${tab}`);
  }
  await expect(close).toBeFocused();
  expect(await close.evaluate(el => el.matches(":focus-visible"))).toBe(true);
  await expect(close).toHaveCSS("outline-style", "solid");
  await page.keyboard.press("Enter");
  const reopen = widget.getByRole("button", { name: "Open conversation" });
  await expect(reopen).toBeFocused();
  await expect(reopen).toHaveCSS("outline-style", "solid");
  await page.keyboard.press("Enter");
  await expect(input).toBeFocused();
});
