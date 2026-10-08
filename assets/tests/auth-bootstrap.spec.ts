import { expect, test } from "@playwright/test";

test("token URL bootstraps in the fragment and renews without remounting", async ({ page, request }) => {
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity");
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    (window as any).publicReadyCount = 0;
    window.addEventListener("message", event => {
      if (event.data?.type === "zaq.widget.ready") (window as any).publicReadyCount++;
    });
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });

  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  await expect.poll(() => widget.locator("body").evaluate(() => location.hash)).toBe("");
  expect(tokens).toBe(1);
  const readyBeforeRenewal = await page.evaluate(() => (window as any).publicReadyCount);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Unsent draft");
  await input.evaluate(element => { (window as any).draftElement = element; });

  await page.evaluate(() => window.zaq.widget.connect());
  await expect.poll(() => tokens).toBe(2);
  await expect(input).toHaveValue("Unsent draft");
  expect(await input.evaluate(element => element === (window as any).draftElement)).toBe(true);
  expect(await page.evaluate(() => (window as any).publicReadyCount)).toBe(readyBeforeRenewal);

  await widget.locator("body").evaluate(() => {
    (window as any).liveSocket.disconnect();
    (window as any).liveSocket.connect();
  });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(2);
});

test("backend disconnect ends only the targeted widget session", async ({ page, request }) => {
  const user = `revoked-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(1);

  const { proof } = await (await request.get("http://127.0.0.1:4021/control-proof", { params: { user_id: user } })).json();
  const disconnect = () => request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${proof}` }, data: { user_id: user },
  });
  const first = await disconnect();
  expect(first.status()).toBe(200);
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  const retry = await disconnect();
  expect(retry.status()).toBe(200);
  expect((await retry.json()).cutoff).toBe((await first.json()).cutoff);
  await page.waitForTimeout(300);
  expect(tokens).toBe(1);
});

test("renewal preserves streamed Markdown, draft, and styled container", async ({ page, request }) => {
  const user = `stream-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await page.route("**/brand.css", route => route.fulfill({
    contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }",
  }));

  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    const container = document.createElement("div");
    container.id = "chat";
    container.style.height = "600px";
    document.body.append(container);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    script.setAttribute("iframe-location-id", "#chat");
    script.setAttribute("stylesheet-url", "/brand.css");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#chat > iframe");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  await input.fill("markdown renewal");
  await input.press("Enter");
  const answer = widget.locator(".zaq-answer-content");
  await expect(answer.locator("strong")).toHaveText("Partial");
  await input.fill("Keep this draft");
  await input.evaluate(element => { (window as any).composerBeforeRenewal = element; });
  await page.evaluate(() => window.zaq.widget.connect());
  await expect(answer.locator("strong")).toHaveText("Finished");
  await expect(answer.locator("h2")).toHaveText("Update");
  await expect(input).toHaveValue("Keep this draft");
  expect(await input.evaluate(element => element === (window as any).composerBeforeRenewal)).toBe(true);
  expect(tokens).toBe(2);
});

test("a lost renewal acknowledgement leaves the active chat usable", async ({ page, request }) => {
  const user = `lost-ack-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await page.goto("/widget/missing");
  await page.evaluate(async () => {
    (window as any).ackDropped = false;
    (window as any).ackDropEnabled = false;
    window.addEventListener("message", event => {
      if (!(window as any).ackDropEnabled || event.data?.type !== "zaq.widget.result" ||
          typeof event.data.credential_id !== "string") return;
      (window as any).ackDropped = true;
      (window as any).ackDropEnabled = false;
      event.stopImmediatePropagation();
    }, true);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.setAttribute("data-widget-id", "420");
    script.setAttribute("data-token-url", "/api/widget-token");
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Embed did not load."));
      document.body.append(script);
    });
  });
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await page.evaluate(() => {
    (window as any).ackDropEnabled = true;
    (window as any).renewalResult = window.zaq.widget.connect()
      .then(() => "accepted", (error: Error) => error.message);
  });
  await expect.poll(() => page.evaluate(() => (window as any).ackDropped)).toBe(true);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  expect(await page.evaluate(() => (window as any).renewalResult)).toBe("Widget request timed out.");
  expect(tokens).toBeGreaterThanOrEqual(2);
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();
});
