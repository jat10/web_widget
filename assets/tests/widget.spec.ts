import { expect, test } from "@playwright/test";

test("floating iframe expands through React → LiveView and preserves the conversation", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/widget-demo");
  const frame = page.locator("#zaq-demo-widget");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });

  await expect(input).toBeVisible();
  await expect(widget.locator("#widget-state")).toHaveAttribute("data-context-received", "true");
  await expect(frame).toHaveAttribute("data-mode", "launcher");
  await expect(widget.locator(".zaq-widget-header")).toHaveCount(0);
  await expect(widget.locator(".zaq-thread")).toHaveCount(0);
  const bounds = await frame.boundingBox();
  expect(bounds!.height).toBeLessThan(200);

  await page.evaluate(() => window.scrollTo(0, 500));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
  expect((await frame.boundingBox())!.y).toBeCloseTo(bounds!.y, 0);

  // A different window cannot expand the iframe by spoofing the event name.
  await page.evaluate(() => window.postMessage({ type: "zaq.widget.resize", mode: "conversation" }, "*"));
  await expect(frame).toHaveAttribute("data-mode", "launcher");

  await input.fill("Where can I learn?");
  await input.press("Enter");
  await expect(frame).toHaveAttribute("data-mode", "conversation");
  await expect(widget.locator("#widget-state")).toHaveAttribute("data-mode", "conversation");
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText("Where can I learn?");
  await expect(widget.locator('[data-kind="tool_call"][data-status="running"]')).toContainText("Searching knowledge base");
  await expect(widget.locator('[data-role="assistant"]')).toContainText("prototype response to “Where can I learn?”");
  await expect(widget.locator('.zaq-activity-toggle')).toHaveAttribute("aria-expanded", "false");
  await widget.locator('.zaq-activity-toggle').click();
  await expect(widget.locator('.zaq-response-step[data-kind="tool_call"][data-status="complete"]')).toBeVisible();
  expect((await frame.boundingBox())!.height).toBeCloseTo(page.viewportSize()!.height, 0);

  await input.fill("What about parks?");
  await expect(widget.getByRole("button", { name: "Send message" })).toBeEnabled();
  await widget.getByRole("button", { name: "Send message" }).click();
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText(["Where can I learn?", "What about parks?"]);
  await expect(widget.locator('[data-role="assistant"]').last()).toContainText("prototype response to “What about parks?”");
  await expect(frame).toHaveAttribute("data-mode", "conversation");
  expect(errors).toEqual([]);
});

test("the conversation scrolls independently of its bottom composer", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 600 });
  await page.goto("/widget-demo");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Tell me about local places to visit. ".repeat(30));
  await input.press("Enter");
  await expect(widget.locator('[data-role="assistant"]')).toContainText("No live search was performed.");
  const composer = widget.locator(".zaq-composer");
  const before = await composer.boundingBox();
  expect(before!.y + before!.height).toBeLessThanOrEqual(600);
  expect(before!.y + before!.height).toBeGreaterThan(550);
  const viewport = widget.locator(".zaq-thread");
  expect(await viewport.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);
  await viewport.evaluate((el) => { el.scrollTop = 0; });
  expect((await composer.boundingBox())!.y).toBeCloseTo(before!.y, 0);
});

test("mobile launcher fits the viewport and Shift+Enter does not submit", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/widget-demo");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await input.fill("  ");
  await expect(widget.getByRole("button", { name: "Send message" })).toBeDisabled();
  await input.fill("First line");
  await input.press("Shift+Enter");
  await input.pressSequentially("Second line");
  await expect(page.locator("#zaq-demo-widget")).toHaveAttribute("data-mode", "launcher");
  const composer = await widget.locator(".zaq-composer").boundingBox();
  expect(composer!.x).toBeGreaterThanOrEqual(12);
  expect(composer!.x + composer!.width).toBeLessThanOrEqual(378);
  await input.press("Enter");
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toContainText("First line");
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toContainText("Second line");
  await expect(widget.locator('[data-role="assistant"]')).toContainText("No live search was performed.");
});

test("bootstrap accepts only valid parent context and announces readiness after reconnect", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(() => {
    if (window.parent !== window) return;
    window.addEventListener("message", (event) => {
      if (event.data?.type === "zaq.widget.ready") {
        event.stopImmediatePropagation();
        document.documentElement.dataset.readyCount = String(
          Number(document.documentElement.dataset.readyCount || 0) + 1,
        );
      }
    });
  });
  await page.goto("/widget-demo");
  const state = page.frameLocator("#zaq-demo-widget").locator("#widget-state");
  await expect(page.locator("html")).toHaveAttribute("data-ready-count", "1");
  await expect(state).toHaveAttribute("data-context-received", "false");
  const child = page.frames().find((frame) => frame.parentFrame())!;

  // Same-origin messages from the iframe itself are not parent bootstrap messages.
  await child.evaluate(() => {
    window.postMessage({ type: "zaq.widget.init", user_id: "spoofed" }, window.location.origin);
    window.dispatchEvent(new MessageEvent("message", {
      source: window.parent,
      origin: "https://untrusted.example",
      data: { type: "zaq.widget.init", user_id: "spoofed" },
    }));
  });
  await page.evaluate(() => {
    const child = document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!;
    for (const data of [
      { type: "unrelated", user_id: "user_123" },
      { type: "zaq.widget.init", user_id: " " },
      { type: "zaq.widget.init", user_id: "user_123", conversation_id: 42 },
      { type: "zaq.widget.init", user_id: "user_123", prompt_context: [] },
      { type: "zaq.widget.init", user_id: "user_123", prompt_context: { value: 1n } },
    ]) child.postMessage(data, window.location.origin);
  });

  // A reconnect is also a barrier: previously queued context would now be visible.
  await child.evaluate(() => (window as any).liveSocket.disconnect());
  await child.evaluate(() => (window as any).liveSocket.connect());
  await expect(page.locator("html")).toHaveAttribute("data-ready-count", "2");
  await expect(state).toHaveAttribute("data-context-received", "false");

  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init",
      user_id: "user_123",
      prompt_context: "Current page: /billing",
      conversation_id: "conv_123",
    }, window.location.origin);
  });
  await expect(state).toHaveAttribute("data-context-received", "true");
  await child.evaluate(() => (window as any).liveSocket.disconnect());
  await child.evaluate(() => (window as any).liveSocket.connect());
  await expect(page.locator("html")).toHaveAttribute("data-ready-count", "3");
  expect(errors).toEqual([]);
});

test("missing user_id keeps chat hidden and console guidance allows late recovery", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  const errors: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error" && message.text().startsWith("[WebWidget]")) errors.push(message.text());
  });
  await page.clock.install();
  await page.addInitScript(() => {
    if (window.parent !== window) return;
    window.addEventListener("message", (event) => {
      if (event.data?.type === "zaq.widget.ready") {
        event.stopImmediatePropagation();
        document.documentElement.dataset.widgetReady = "true";
      }
    });
  });
  await page.goto("/widget-demo");
  await expect(page.locator("html")).toHaveAttribute("data-widget-ready", "true");
  const widget = page.frameLocator("#zaq-demo-widget");
  await expect(widget.locator("#web-widget")).toHaveCount(0);
  for (const selector of ["html", "body"]) {
    await expect(widget.locator(selector)).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    await expect(widget.locator(selector)).toHaveCSS("color-scheme", "light dark");
  }
  await page.clock.runFor(5100);
  await expect.poll(() => errors.some((error) => error.includes("No valid user_id received"))).toBe(true);
  expect(errors[0]).toContain('iframe.contentWindow.postMessage');
  expect(errors[0]).toContain('zaq.widget.ready');
  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init", prompt_context: "Billing",
    }, window.location.origin);
  });
  await expect.poll(() => errors.some((error) => error.includes("Missing or invalid user_id"))).toBe(true);
  await expect(widget.locator("#web-widget")).toHaveCount(0);
  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init", user_id: "user_123", prompt_context: { page: "/billing" },
    }, window.location.origin);
  });
  await expect.poll(() => errors.some((error) => error.includes("Invalid prompt_context"))).toBe(true);
  await expect(widget.locator("#web-widget")).toHaveCount(0);
  await page.evaluate(() => {
    document.querySelector<HTMLIFrameElement>("#zaq-demo-widget")!.contentWindow!.postMessage({
      type: "zaq.widget.init", user_id: "user_123", prompt_context: "Billing", conversation_id: null,
    }, window.location.origin);
  });
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();
  const errorCount = errors.length;
  await page.clock.runFor(5100);
  expect(errors).toHaveLength(errorCount);
});

test("close collapses the iframe and reopening preserves drafts and live responses", async ({ page }) => {
  await page.goto("/widget-demo");
  const frame = page.locator("#zaq-demo-widget");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("research");
  await input.press("Enter");
  await expect(widget.locator('.zaq-response-step[data-status="running"]').first()).toBeVisible();
  await input.fill("My follow-up draft");
  await widget.getByRole("button", { name: "Close chat", exact: true }).click();
  await expect(frame).toHaveAttribute("data-mode", "launcher");
  await expect(widget.locator(".zaq-widget-header")).toHaveCount(0);
  await expect(input).toHaveValue("My follow-up draft");
  await expect(widget.getByRole("button", { name: "Open conversation" })).toBeFocused();
  expect((await frame.boundingBox())!.height).toBeLessThan(260);
  expect(await page.evaluate(() => document.documentElement.style.overflow)).not.toBe("hidden");
  await page.evaluate(() => window.scrollTo(0, 400));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
  await expect(widget.getByRole("button", { name: "Send message" })).toBeEnabled();
  await widget.getByRole("button", { name: "Open conversation" }).click();
  await expect(frame).toHaveAttribute("data-mode", "conversation");
  await expect(input).toBeFocused();
  await expect(input).toHaveValue("My follow-up draft");
  await expect(widget.locator('[data-role="user"] .zaq-user-content')).toHaveText("research");
  await expect(widget.locator(".zaq-answer-content")).toContainText("prototype response");
  await expect(widget.locator(".zaq-activity-toggle")).toContainText("2 steps completed");
});
