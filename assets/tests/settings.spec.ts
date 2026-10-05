import { expect, test, type Page } from "@playwright/test";

async function client(page: Page, id = "settings-widget", path = "theme-dark", origin = "http://127.0.0.1:4019") {
  await page.evaluate(async ({ id, path, origin }) => {
    const moduleUrl = `${origin}/web_widget/assets/widget-client.js`;
    const { createWidgetClient } = await import(moduleUrl);
    const frame = document.createElement("iframe");
    frame.id = id;
    frame.style.cssText = "width:600px;height:700px;border:0;color-scheme:light dark";
    document.body.append(frame);
    (window as any)[id] = createWidgetClient(frame, `${origin}/widget/${path}`);
  }, { id, path, origin });
  return page.frameLocator(`#${id}`);
}

test("parent client initializes across origins and updates partial settings with applied acknowledgements", async ({ page }) => {
  await page.goto("/widget/missing");
  const widget = await client(page, "settings-widget", "theme-dark", "http://127.0.0.1:4020");
  await page.evaluate(() => (window as any)["settings-widget"].init({ user_id: "settings-user" }));
  expect(await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ language: "fr", theme: "dark" }))).toEqual({ theme: "dark", language: "fr" });
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toHaveAttribute("placeholder", "Posez une question…");
  await expect(widget.locator(".zaq-widget")).toHaveCSS("color-scheme", "dark");
  await page.emulateMedia({ colorScheme: "dark" });
  expect(await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ theme: "light" }))).toEqual({ theme: "light", language: "fr" });
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ theme: "auto", language: "ar" }));
  await expect(widget.locator("html")).toHaveAttribute("dir", "rtl");
  await expect(widget.getByRole("textbox", { name: "الرسالة", exact: true })).toBeVisible();
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(13, 20, 28)");
  await page.emulateMedia({ colorScheme: "light" });
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
});

test("invalid settings are atomic and ordered updates preserve omitted values", async ({ page }) => {
  await page.goto("/widget/missing");
  const widget = await client(page);
  expect(await page.evaluate(() => (window as any)["settings-widget"].getSettings())).toEqual({ theme: "light", language: "en" });
  expect(await page.evaluate(async () => {
    try { await (window as any)["settings-widget"].init({ user_id: "settings-user", settings: { theme: "dark", language: "de" } }); return false; } catch { return true; }
  })).toBe(true);
  await expect(widget.locator("#web-widget")).toHaveCount(0);
  await page.evaluate(() => (window as any)["settings-widget"].init({ user_id: "settings-user" }));
  for (const patch of [null, [], { theme: "light", language: "de" }, { theme: "light", user_id: "other" }]) {
    expect(await page.evaluate(async patch => {
      try { await (window as any)["settings-widget"].updateSettings(patch); return false; } catch { return true; }
    }, patch)).toBe(true);
    expect(await page.evaluate(() => (window as any)["settings-widget"].getSettings())).toEqual({ theme: "light", language: "en" });
  }
  expect(await page.evaluate(() => Promise.all([
    (window as any)["settings-widget"].updateSettings({ theme: "dark" }),
    (window as any)["settings-widget"].updateSettings({ language: "fr" }),
  ]))).toEqual([{ theme: "dark", language: "en" }, { theme: "dark", language: "fr" }]);
});

test("settings preserve an active response, draft and selected conversation", async ({ page, request }) => {
  const user = crypto.randomUUID();
  expect((await request.post(`http://127.0.0.1:4021/sessions/${user}`, { data: { hold: true } })).ok()).toBe(true);
  await page.goto("/widget/missing");
  const widget = await client(page, "settings-widget", "e2e-multi");
  await page.evaluate(user => (window as any)["settings-widget"].init({ user_id: user }), user);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Keep this request"); await input.press("Enter");
  await expect(widget.locator(".zaq-answer-content")).toContainText("Partial reply");
  await input.fill("Keep this draft");
  const selected = await widget.locator('[aria-current="page"]').textContent();
  await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ language: "ar", theme: "dark" }));
  await expect(widget.getByRole("textbox", { name: "الرسالة", exact: true })).toHaveValue("Keep this draft");
  await expect(widget.locator('[aria-current="page"]')).toHaveText(selected!);
  await expect(widget.locator(".zaq-message-assistant")).toHaveAttribute("data-running", "true");
  expect((await request.post(`http://127.0.0.1:4021/sessions/${user}/complete`, { data: { fail: false } })).ok()).toBe(true);
  await expect(widget.locator(".zaq-answer-content")).toHaveText("Controlled host reply");
  const events = (await (await request.get(`http://127.0.0.1:4021/sessions/${user}`)).json()).events;
  expect(events.filter((e: any) => e.type === "message.create")).toHaveLength(1);
});

test("runtime preferences survive reconnect and stale init; client reapplies them after reload", async ({ page }) => {
  await page.goto("/widget/missing");
  const widget = await client(page);
  await page.evaluate(() => (window as any)["settings-widget"].init({ user_id: "settings-user" }));
  await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ language: "fr", theme: "light" }));
  await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ language: "ar", theme: "dark" }));
  const frame = page.frames().find(frame => frame.parentFrame())!;
  await frame.evaluate(() => new Promise<void>(resolve => (window as any).liveSocket.disconnect(resolve)));
  await frame.evaluate(() => (window as any).liveSocket.connect());
  expect(await page.evaluate(() => (window as any)["settings-widget"].getSettings())).toEqual({ theme: "dark", language: "ar" });
  expect(await page.evaluate(async () => {
    try { await (window as any)["settings-widget"].init({ user_id: "settings-user", settings: { theme: "light", language: "en" } }); return false; }
    catch { return true; }
  })).toBe(true);
  await expect(widget.locator("html")).toHaveAttribute("lang", "ar");
  await frame.goto(frame.url());
  await expect(widget.getByRole("textbox", { name: "الرسالة", exact: true })).toBeVisible();
  await expect(widget.locator(".zaq-widget")).toHaveCSS("color-scheme", "dark");
});

test("preferences set before init survive reconnect without starting a conversation", async ({ page }) => {
  await page.goto("/widget/missing");
  const widget = await client(page);
  await page.evaluate(() => (window as any)["settings-widget"].updateSettings({ language: "fr", theme: "dark" }));
  const frame = page.frames().find(frame => frame.parentFrame())!;
  await frame.evaluate(() => new Promise<void>(resolve => (window as any).liveSocket.disconnect(resolve)));
  await frame.evaluate(() => (window as any).liveSocket.connect());
  expect(await page.evaluate(() => (window as any)["settings-widget"].getSettings())).toEqual({ theme: "dark", language: "fr" });
  await expect(widget.locator("#web-widget")).toHaveCount(0);
  await page.evaluate(() => (window as any)["settings-widget"].init({ user_id: "settings-user" }));
  await expect(widget.getByRole("textbox", { name: "Message", exact: true })).toHaveAttribute("placeholder", "Posez une question…");
  await expect(widget.locator(".zaq-widget")).toHaveCSS("color-scheme", "dark");
});

test("sibling and untrusted-origin settings cannot affect another widget", async ({ page }) => {
  await page.goto("/widget/missing");
  const first = await client(page, "first"); const second = await client(page, "second");
  await page.evaluate(() => Promise.all([(window as any).first.init({ user_id: "first" }), (window as any).second.init({ user_id: "second" })]));
  await page.evaluate(() => (window as any).first.updateSettings({ language: "ar", theme: "dark" }));
  await expect(first.locator("html")).toHaveAttribute("lang", "ar");
  await expect(second.locator("html")).toHaveAttribute("lang", "en");
  const frames = page.frames().filter(f => f.parentFrame());
  await frames[0].evaluate(() => {
    const other = (window.parent.document.querySelector("#second") as HTMLIFrameElement).contentWindow!;
    other.postMessage({ type: "zaq.widget.settings.update", settings: { language: "ar" } }, location.origin);
  });
  await frames[1].evaluate(() => window.dispatchEvent(new MessageEvent("message", { source: window.parent, origin: "https://untrusted.example", data: { type: "zaq.widget.settings.update", settings: { language: "ar" } } })));
  expect(await page.evaluate(() => (window as any).second.getSettings())).toEqual({ theme: "light", language: "en" });
  await page.evaluate(() => (window as any).second.dispose());
  expect(await page.evaluate(async () => { try { await (window as any).second.getSettings(); return false; } catch { return true; } })).toBe(true);
});
