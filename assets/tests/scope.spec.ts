import { expect, test } from "@playwright/test";

test("trusted scope serves generated assets, authenticated iframe and WSS through TLS proxy, then signed disconnect", async ({ page, request, context }) => {
  const user = `scoped-${test.info().project.name}`;
  const errors: string[] = [];
  const assets: string[] = [];
  const sockets: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("request", req => {
    if (req.url().includes("/web_widget/assets/")) assets.push(new URL(req.url()).pathname);
  });
  page.on("websocket", socket => sockets.push(socket.url()));
  const { snippet } = await (await request.get("http://127.0.0.1:4021/installation")).json();
  expect(snippet).toContain("https://localhost:4023/channels/web_widget/assets/embed.js");
  expect(snippet).toContain("https://localhost:4023/channels/widget/421");
  await page.route("**/scoped-parent", route => route.fulfill({
    contentType: "text/html", body: `<!doctype html><div id="zaq-widget" style="height:650px;width:600px"></div>${snippet.replace(" defer>", ' iframe-location-id="#zaq-widget" defer>')}`,
  }));
  await page.route("**/scoped-identity", async route => {
    const response = await request.get(`http://127.0.0.1:4021/identity?widget_id=421&user_id=${user}`);
    await route.fulfill({ contentType: "application/json", body: await response.text(), headers: { "cache-control": "no-store" } });
  });
  await page.goto("/scoped-parent");
  const widget = page.frameLocator("#zaq-widget-frame");
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  expect(assets).toContain("/channels/web_widget/assets/app.js");
  expect(assets).toContain("/channels/web_widget/assets/app.css");
  expect(assets.every(path => path.startsWith("/channels/web_widget/assets/"))).toBe(true);
  expect(sockets.some(url => url.startsWith("wss://localhost:4023/channels/widget/421/live/websocket"))).toBe(true);
  const cookies = (await context.cookies()).filter(cookie => cookie.name === "_web_widget_session");
  expect(cookies).toHaveLength(1);
  expect(cookies[0]).toMatchObject({ path: "/channels/widget/421", secure: true, httpOnly: true, sameSite: "None" });
  const status = await (await request.get("http://127.0.0.1:4021/scope-status")).json();
  expect(status.status).toBe("ok");
  expect(status.verification).toMatchObject({ session_handshake: "not_checked", external_https: "not_checked" });
  const { proof } = await (await request.get(`http://127.0.0.1:4021/scoped-proof?user_id=${user}`)).json();
  const wrong = await request.post("/widget-api/421/disconnect", { data: { user_id: user }, headers: { authorization: `Bearer ${proof}` } });
  expect(wrong.status()).toBe(401);
  const disconnected = await request.post("/channels/widget-api/421/disconnect", { data: { user_id: user }, headers: { authorization: `Bearer ${proof}` } });
  expect(disconnected.status()).toBe(200);
  await expect(widget.getByText("Refresh the page to reconnect.", { exact: true })).toBeVisible();
  expect(errors).toEqual([]);
});
