import { expect, test } from "@playwright/test";

test("generated installation script authenticates, chats and restores with a fresh backend proof", async ({ page, request }) => {
  const bootstrap = await (await request.get("http://127.0.0.1:4021/identity")).json();
  await page.goto("/widget/missing");
  await page.evaluate(async ({ installation_script }) => {
    const parsed = new DOMParser().parseFromString(installation_script, "text/html");
    const source = parsed.querySelector("script")!;
    const script = document.createElement("script");
    for (const attribute of source.attributes) script.setAttribute(attribute.name, attribute.value);
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve(); script.onerror = () => reject(new Error("Loader failed"));
      document.body.append(script);
    });
  }, bootstrap);
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-state")).toBeAttached();
  await expect(widget.locator(".zaq-widget")).toHaveCount(0);
  await page.evaluate(async identity_token => {
    const frame = document.getElementById("zaq-widget")!;
    frame.addEventListener("zaq:conversation", (event: any) => {
      sessionStorage.setItem("smoke-conversation", event.detail.conversation_id);
    });
    await window.zaq.widget.init({ identity_token });
  }, bootstrap.identity_token);
  await expect(widget.locator(".zaq-widget")).toBeVisible();
  expect(await page.evaluate(async identity_token => {
    for (const override of [{ user_id: "other" }, { conversation_id: "foreign" }, { prompt_context: "unsigned" }, { settings: { theme: "dark" } }, { params: {} }]) {
      try { await window.zaq.widget.init({ identity_token, ...override } as any); return false; }
      catch { /* unsigned init extensions must fail */ }
    }
    return true;
  }, bootstrap.identity_token)).toBe(true);
  await widget.getByPlaceholder("Ask a question…").fill("instant");
  await widget.getByPlaceholder("Ask a question…").press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await expect.poll(() => page.evaluate(() => sessionStorage.getItem("smoke-conversation"))).toBe("conversation-1");

  // Full iframe reload needs a newly minted proof, then canonical host history.
  const savedId = await page.evaluate(() => sessionStorage.getItem("smoke-conversation"));
  const fresh = await (await request.get("http://127.0.0.1:4021/identity", { params: { conversation_id: savedId! } })).json();
  await page.evaluate(() => new Promise<void>((resolve, reject) => {
    const frame = document.getElementById("zaq-widget") as HTMLIFrameElement;
    const timer = setTimeout(() => reject(new Error("Missing reauthentication request")), 10000);
    frame.addEventListener("zaq:authentication-required", () => {
      clearTimeout(timer); resolve();
    }, { once: true });
    frame.src = frame.src;
  }));
  await page.evaluate(identity_token => window.zaq.widget.init({ identity_token }), fresh.identity_token);
  await expect(widget.getByText("Saved answer", { exact: true })).toBeVisible();
  await expect(widget.locator("#widget-instance-stylesheet")).toHaveCount(0);
  expect(await page.evaluate(async () => {
    let renewals = 0;
    const frame = document.getElementById("zaq-widget")!;
    const count = () => { renewals++; };
    frame.addEventListener("zaq:authentication-required", count);
    try { await window.zaq.widget.updateSettings({ theme: "invalid" } as any); } catch { /* expected */ }
    try { await window.zaq.widget.init({ identity_token: "invalid" }); } catch { /* expected */ }
    frame.removeEventListener("zaq:authentication-required", count);
    return renewals;
  })).toBe(0);
});

test("token expiry and renewal preserve the mounted chat and draft", async ({ page, request }) => {
  const bootstrap = await (await request.get("http://127.0.0.1:4021/identity?short=true")).json();
  await page.goto("/widget/missing");
  await page.evaluate(async ({ installation_script, identity_token }) => {
    const source = new DOMParser().parseFromString(installation_script, "text/html").querySelector("script")!;
    const script = document.createElement("script");
    for (const attribute of source.attributes) script.setAttribute(attribute.name, attribute.value);
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve(); script.onerror = () => reject(new Error("Loader failed"));
      document.body.append(script);
    });
    const frame = document.getElementById("zaq-widget")!;
    frame.addEventListener("zaq:authentication-required", () => frame.dataset.expired = "true");
    await window.zaq.widget.init({ identity_token });
  }, bootstrap);
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await input.fill("Keep this unsent draft");
  await input.evaluate(element => { (window as any).originalComposer = element; });
  await expect(page.locator("#zaq-widget")).toHaveAttribute("data-expired", "true", { timeout: 6000 });
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await expect(input).toHaveValue("Keep this unsent draft");
  await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeDisabled();
  expect(await input.evaluate(element => element === (window as any).originalComposer)).toBe(true);
  const fresh = await (await request.get("http://127.0.0.1:4021/identity?conversation_id=conversation-1")).json();
  await page.evaluate(identity_token => window.zaq.widget.init({ identity_token }), fresh.identity_token);
  await expect(widget.getByText("Saved answer", { exact: true })).toBeVisible();
  await expect(input).toHaveValue("Keep this unsent draft");
  await expect(widget.getByRole("button", { name: "Send message", exact: true })).toBeEnabled();
  expect(await input.evaluate(element => element === (window as any).originalComposer)).toBe(true);
});
