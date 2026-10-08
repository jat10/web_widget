import { expect, test, type Page, type Route } from "@playwright/test";

async function installTokenWidget(page: Page) {
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
}

test("token URL bootstraps in the fragment and renews without remounting", async ({ page, request }) => {
  let tokens = 0;
  let failRenewal = false;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    if (failRenewal) return route.fulfill({ status: 503, body: "unavailable" });
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
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
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

  failRenewal = true;
  await expect(page.evaluate(() => window.zaq.widget.connect())).rejects.toThrow("Widget token endpoint failed.");
  expect(tokens).toBe(3);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await widget.locator("body").evaluate(() => {
    (window as any).liveSocket.disconnect();
    (window as any).liveSocket.connect();
  });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(3);
});

test("backend disconnect closes every targeted tab and a fresh credential restores access", async ({ page, context, request }) => {
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

  const other = await context.newPage();
  await other.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(other);
  const otherWidget = other.frameLocator("#zaq-widget");
  await expect(otherWidget.locator(".zaq-widget")).toBeVisible();
  expect(tokens).toBe(2);

  const { proof } = await (await request.get("http://127.0.0.1:4021/control-proof", { params: { user_id: user } })).json();
  const disconnect = () => request.post("http://127.0.0.1:4020/widget-api/420/disconnect", {
    headers: { Authorization: `Bearer ${proof}` }, data: { user_id: user },
  });
  const first = await disconnect();
  expect(first.status()).toBe(200);
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await expect(otherWidget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  const retry = await disconnect();
  expect(retry.status()).toBe(200);
  expect((await retry.json()).cutoff).toBe((await first.json()).cutoff);
  await page.waitForTimeout(300);
  expect(tokens).toBe(2);
  const cutoff = (await first.json()).cutoff;
  await expect.poll(() => Math.floor(Date.now() / 1000)).toBeGreaterThan(cutoff);
  await other.evaluate(() => window.zaq.widget.dispose());
  await other.evaluate(() => window.zaq.widget.mountAuthenticated("http://127.0.0.1:4020/widget/420"));
  await expect(otherWidget.locator(".zaq-widget")).toBeVisible();
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await otherWidget.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(otherWidget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await expect(widget.locator("#widget-backend-revoked")).toHaveText("Refresh the page to reconnect.");
  await other.close();
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
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect.poll(() => widget.locator("body").evaluate(() => location.hash)).toBe("");
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  const frame = page.locator("#chat > iframe");
  await frame.evaluate(element => { (window as any).authenticatedFrame = element; });
  await input.fill("markdown renewal");
  await input.press("Enter");
  await expect(widget.getByText("markdown renewal", { exact: true })).toBeVisible();
  const answer = widget.locator(".zaq-answer-content");
  await expect(answer.locator("strong")).toHaveText("Partial");
  await input.fill("Keep this draft");
  await input.evaluate(element => { (window as any).composerBeforeRenewal = element; });
  await page.evaluate(() => window.zaq.widget.connect());
  await expect(answer.locator("strong")).toHaveText("Finished");
  await expect(answer.locator("h2")).toHaveText("Update");
  await expect(input).toHaveValue("Keep this draft");
  expect(await input.evaluate(element => element === (window as any).composerBeforeRenewal)).toBe(true);
  expect(await frame.evaluate(element => element === (window as any).authenticatedFrame)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  expect(tokens).toBe(2);
  await frame.evaluate(element => {
    element.addEventListener("zaq:ready", () => { (window as any).reconnectedReady = true; }, { once: true });
  });
  await widget.locator("body").evaluate(() => {
    (window as any).liveSocket.disconnect();
    (window as any).liveSocket.connect();
  });
  await expect.poll(() => page.evaluate(() => (window as any).reconnectedReady === true)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  expect(tokens).toBe(2);
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
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

test("a JWT bound to one browser page cannot bootstrap another page", async ({ page, context, request }) => {
  const { identity_token } = await (await request.get("http://127.0.0.1:4021/identity", {
    params: { user_id: `replay-${crypto.randomUUID()}` },
  })).json();
  const tokenResponse = async (route: Route) => route.fulfill({
    status: 200,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
    body: JSON.stringify({ identity_token }),
  });
  await page.route("**/api/widget-token", tokenResponse);
  await installTokenWidget(page);
  const first = page.frameLocator("#zaq-widget");
  await expect(first.locator("#widget-context")).toHaveAttribute("data-authorized", "true");

  const other = await context.newPage();
  await other.route("**/api/widget-token", tokenResponse);
  await installTokenWidget(other);
  const replay = other.frameLocator("#zaq-widget");
  await expect(replay.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
  await expect(replay.locator(".zaq-widget")).toHaveCount(0);
  await first.getByRole("textbox", { name: "Message", exact: true }).fill("instant");
  await first.getByRole("textbox", { name: "Message", exact: true }).press("Enter");
  await expect(first.getByText("Immediate answer", { exact: true })).toBeVisible();
  await other.close();
});

test("a short credential renews automatically before expiry", async ({ page, request }) => {
  const user = `automatic-${crypto.randomUUID()}`;
  let tokens = 0;
  await page.route("**/api/widget-token", async route => {
    tokens++;
    const issued = await request.get("http://127.0.0.1:4021/identity", {
      params: { user_id: user, ...(tokens === 1 ? { short: "true" } : {}) },
    });
    const { identity_token } = await issued.json();
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "cache-control": "no-store" },
      body: JSON.stringify({ identity_token }),
    });
  });
  await installTokenWidget(page);
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  const initialCredential = await widget.locator("#widget-context").getAttribute("data-auth-credential-id");
  const initialExpiry = Number(await widget.locator("#widget-context").getAttribute("data-auth-expires-at"));
  const frame = page.locator("#zaq-widget");
  await frame.evaluate(element => { (window as any).automaticFrame = element; });
  await input.fill("Preserved while refreshing");
  await expect.poll(() => tokens, { timeout: 6000 }).toBe(2);
  await expect(widget.locator("#widget-context")).not.toHaveAttribute("data-auth-credential-id", initialCredential!);
  await expect.poll(() => Math.floor(Date.now() / 1000)).toBeGreaterThan(initialExpiry);
  await expect(input).toHaveValue("Preserved while refreshing");
  expect(await frame.evaluate(element => element === (window as any).automaticFrame)).toBe(true);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
});

test("invalid JWT and token endpoint failures block bootstrap, then a valid endpoint recovers", async ({ page, request }) => {
  const { identity_token } = await (await request.get("http://127.0.0.1:4021/identity", {
    params: { user_id: `recovery-${crypto.randomUUID()}` },
  })).json();
  const parts = identity_token.split(".");
  parts[2] = (parts[2][0] === "A" ? "B" : "A") + parts[2].slice(1);
  const invalidToken = parts.join(".");
  let response: "http" | "cache" | "invalid" | "valid" = "http";
  await page.route("**/api/widget-token", route => {
    if (response === "http") return route.fulfill({ status: 503, body: "unavailable" });
    return route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", ...(response === "cache" ? {} : { "cache-control": "no-store" }) },
      body: JSON.stringify({ identity_token: response === "invalid" ? invalidToken : identity_token }),
    });
  });
  await installTokenWidget(page);
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  const mount = () => page.evaluate(async () => {
    try {
      await window.zaq.widget.mountAuthenticated("http://127.0.0.1:4020/widget/420");
      return "mounted";
    } catch (error) {
      return (error as Error).message;
    }
  });
  response = "cache";
  expect(await mount()).toBe("Widget token endpoint must return Cache-Control: no-store.");
  await expect(page.locator("#zaq-widget")).toHaveCount(0);
  response = "invalid";
  expect(await mount()).toBe("mounted");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "false");
  await expect(widget.locator(".zaq-widget")).toHaveCount(0);
  response = "valid";
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true", { timeout: 10_000 });
  await expect(widget.locator(".zaq-widget")).toBeVisible();
});
