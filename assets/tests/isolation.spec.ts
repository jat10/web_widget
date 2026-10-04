import { expect, test } from "@playwright/test";

test("two widgets isolate bootstrap context, messages and iframe resizing", async ({ page }) => {
  await page.addInitScript(() => {
    if (window.parent !== window) return;
    // Supply distinct contexts explicitly instead of the demo's automatic bootstrap.
    window.addEventListener("message", event => {
      if (event.origin !== window.location.origin || event.data?.type !== "zaq.widget.ready") return;
      const frame = Array.from(document.querySelectorAll("iframe"))
        .find(frame => frame.contentWindow === event.source);
      if (frame) frame.dataset.ready = "true";
      event.stopImmediatePropagation();
    });
  });
  await page.goto("/widget-demo?widget_id=multi");
  await page.evaluate(() => {
    const first = document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!;
    first.style.cssText = "position:fixed;left:0;right:auto;bottom:0;width:50%;height:180px";
    const second = document.createElement("iframe");
    second.id = "second-widget";
    second.dataset.mode = "launcher";
    second.style.cssText = "position:fixed;right:0;bottom:0;width:50%;height:180px";
    // The demo listener still owns the first iframe. This embedding listener owns only the second.
    window.addEventListener("message", event => {
      if (event.source !== second.contentWindow || event.origin !== window.location.origin) return;
      if (event.data?.type !== "zaq.widget.resize") return;
      const { mode, height } = event.data;
      if (mode === "conversation") second.style.height = "100dvh";
      else if (mode === "launcher" && typeof height === "number" && Number.isFinite(height)) {
        second.style.height = `${Math.min(260, Math.max(96, height))}px`;
      } else return;
      second.dataset.mode = mode;
    });
    second.src = "/widget/theme-dark";
    document.body.append(second);
  });

  const firstFrame = page.locator("#zaq-demo-widget");
  const secondFrame = page.locator("#second-widget");
  const first = page.frameLocator("#zaq-demo-widget");
  const second = page.frameLocator("#second-widget");
  await expect(firstFrame).toHaveAttribute("data-ready", "true");
  await expect(secondFrame).toHaveAttribute("data-ready", "true");

  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init", user_id: "first-user", prompt_context: "Weekend planning",
      conversation_id: "mock-weekend",
    }, window.location.origin);
  });
  const firstInput = first.getByRole("textbox", { name: "Message", exact: true });
  const secondInput = second.getByRole("textbox", { name: "Message", exact: true });
  await expect(firstInput).toBeVisible();
  await expect(second.locator("#widget-state")).toHaveAttribute("data-context-received", "false");
  await expect(secondInput).toHaveCount(0);

  // A same-origin sibling is still not the embedding parent. The second message
  // is a processing barrier so rejection is asserted after the spoof is handled.
  await second.locator("#widget-state").evaluate(state => {
    window.addEventListener("message", event => {
      if (event.data?.type === "test.context-barrier") state.setAttribute("data-barrier", "received");
    });
  });
  await firstInput.evaluate(() => {
    const sibling = window.parent.frames[1];
    sibling.postMessage({ type: "zaq.widget.init", user_id: "first-user", conversation_id: "mock-weekend" }, window.location.origin);
    sibling.postMessage({ type: "test.context-barrier" }, window.location.origin);
  });
  await expect(second.locator("#widget-state")).toHaveAttribute("data-barrier", "received");
  await expect(second.locator("#widget-state")).toHaveAttribute("data-context-received", "false");

  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#second-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init", user_id: "second-user", prompt_context: "Billing help",
      conversation_id: "mock-billing",
    }, window.location.origin);
  });
  await expect(secondInput).toBeVisible();
  await expect(secondFrame).toHaveAttribute("data-mode", "launcher");
  const secondHeight = (await secondFrame.boundingBox())!.height;
  await secondInput.fill("Second widget only");
  await firstInput.fill("First widget only");
  await firstInput.press("Enter");
  await expect(firstFrame).toHaveAttribute("data-mode", "conversation");
  await expect(secondFrame).toHaveAttribute("data-mode", "launcher");
  expect((await secondFrame.boundingBox())!.height).toBeCloseTo(secondHeight, 0);
  await expect(secondInput).toHaveValue("Second widget only");

  await secondInput.press("Enter");
  await expect(secondFrame).toHaveAttribute("data-mode", "conversation");
  await expect(first.locator(".zaq-answer-content").last()).toContainText("prototype response to “First widget only”");
  await expect(second.locator(".zaq-answer-content").last()).toContainText("prototype response to “Second widget only”");
  await expect(first.getByRole("button", { name: "Send message" })).toHaveText("Send");
  await expect(second.getByRole("button", { name: "Send message" })).toHaveText("Send");
  await expect(first.locator('[data-role="user"] .zaq-user-content')).toHaveText([
    "Can you help me plan a weekend outside?", "Walking, somewhere quiet.", "First widget only",
  ]);
  await expect(second.locator('[data-role="user"] .zaq-user-content')).toHaveText([
    "I have a question about my latest bill.", "There are two entries for this month.",
    "Yes, I upgraded yesterday.", "Second widget only",
  ]);
  await expect(first.locator('[data-role="assistant"]')).toHaveCount(3);
  await expect(second.locator('[data-role="assistant"]')).toHaveCount(4);

  await second.getByRole("button", { name: "Close chat", exact: true }).click();
  await expect(secondFrame).toHaveAttribute("data-mode", "launcher");
  await expect(firstFrame).toHaveAttribute("data-mode", "conversation");
  expect((await firstFrame.boundingBox())!.height).toBeCloseTo(page.viewportSize()!.height, 0);
  await second.getByRole("button", { name: "Open conversation" }).click();
  await expect(secondFrame).toHaveAttribute("data-mode", "conversation");
  await first.getByRole("button", { name: "Close chat", exact: true }).click();
  await expect(firstFrame).toHaveAttribute("data-mode", "launcher");
  await expect(secondFrame).toHaveAttribute("data-mode", "conversation");
  expect((await secondFrame.boundingBox())!.height).toBeCloseTo(page.viewportSize()!.height, 0);
});

test("rapid double-clicks and repeated Enter accept only one message per submission", async ({ page }) => {
  for (const gesture of ["double-click", "Enter"]) {
    await page.goto("/widget-demo");
    const widget = page.frameLocator("#zaq-demo-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    const send = widget.getByRole("button", { name: "Send message" });
    // Open the conversation first so expansion cannot move the second click off the button.
    await input.fill("hello");
    await input.press("Enter");
    await expect(widget.locator(".zaq-answer-content")).toHaveText("Hello! How can I help you today?");
    await expect(send).toHaveText("Send");

    const message = `Only once via ${gesture}`;
    await input.fill(message);
    await expect(send).toBeEnabled();
    if (gesture === "double-click") await send.dblclick();
    else {
      await input.press("Enter");
      await page.keyboard.press("Enter");
      await page.keyboard.press("Enter");
    }
    await expect(send).toBeDisabled();
    await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText(["hello", message]);
    await expect(widget.locator(".zaq-answer-content").last()).toContainText(`prototype response to “${message}”`);
    await expect(send).toHaveText("Send");
    await expect(widget.locator('[data-role="user"]')).toHaveCount(2);
    await expect(widget.locator('[data-role="assistant"]')).toHaveCount(2);
    // Enter presses delivered after submission can insert newlines while busy.
    // The submitted text must be gone and must not create another message.
    await expect(input).toHaveValue(gesture === "Enter" ? /^\n*$/ : "");
  }
});
