import { expect, test } from "@playwright/test";

test("installation script creates one frame without inventing identity and disposes it", async ({ page }) => {
  await page.goto("/widget/missing");
  const addSnippet = () => page.evaluate(() => new Promise<void>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.dataset.widgetId = "42";
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Loader failed"));
    document.body.append(script);
  }));
  await addSnippet();
  const frame = page.locator("#zaq-widget");
  await expect(frame).toHaveAttribute("src", "http://127.0.0.1:4020/widget/42");
  await expect(frame).toHaveCSS("position", "fixed");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-state")).toBeAttached();
  await expect(widget.locator(".zaq-widget")).toHaveCount(0);
  await addSnippet();
  await expect(frame).toHaveCount(1);
  // Explicit demo identity still uses the existing client; production proof is separate work.
  await page.evaluate(() => window.zaq.widget.init({ user_id: "installed-demo-user" }));
  await expect(widget.locator(".zaq-widget")).toHaveCount(1);
  await page.evaluate(() => window.zaq.widget.dispose());
  await expect(frame).toHaveCount(0);
  await addSnippet();
  await expect(frame).toHaveCount(1);
});

test("installation refuses invalid IDs and does not replace an existing widget", async ({ page }) => {
  await page.goto("/widget/missing");
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.evaluate(() => {
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.dataset.widgetId = "../other";
    document.body.append(script);
  });
  await expect.poll(() => errors).toContain("Invalid widget ID.");
  await expect(page.locator("iframe")).toHaveCount(0);
  await page.evaluate(() => {
    const iframe = document.createElement("iframe");
    iframe.id = "zaq-widget";
    iframe.src = "http://127.0.0.1:4020/widget/theme-dark";
    document.body.append(iframe);
    window.zaq.widget.mount(iframe.src);
  });
  expect(await page.evaluate(() => {
    try { window.zaq.widget.mount("http://127.0.0.1:4020/widget/42"); return false; }
    catch { return true; }
  })).toBe(true);
  await expect(page.locator("#zaq-widget")).toHaveAttribute("src", /theme-dark$/);
  await page.evaluate(() => window.zaq.widget.dispose());
  await expect(page.locator("#zaq-widget")).toHaveCount(1);
});

for (const timing of ["before", "after"] as const) {
  test(`global embed initializes ${timing} iframe readiness and manages layout`, async ({ page }) => {
    await page.goto("/widget/missing");
    let releaseFrame!: () => void;
    if (timing === "before") {
      const gate = new Promise<void>(resolve => { releaseFrame = resolve; });
      await page.route("http://127.0.0.1:4020/widget/theme-dark", async route => {
        await gate;
        await route.continue();
      });
    }
    await page.evaluate(() => {
      document.documentElement.style.overflow = "auto";
      const iframe = document.createElement("iframe");
      iframe.id = "zaq-widget";
      iframe.src = "http://127.0.0.1:4020/widget/theme-dark";
      document.body.append(iframe);
    });
    const widget = page.frameLocator("#zaq-widget");
    if (timing === "after") {
      await expect(widget.locator("#widget-state")).toBeAttached();
      // The hook must be ready before attaching the parent client.
      await expect.poll(() => page.evaluate(() => new Promise<boolean>(resolve => {
        const iframe = document.querySelector<HTMLIFrameElement>("#zaq-widget")!;
        const timer = setTimeout(() => { window.removeEventListener("message", listener); resolve(false); }, 300);
        function listener(event: MessageEvent) {
          if (event.source === iframe.contentWindow && event.origin === "http://127.0.0.1:4020" && event.data?.type === "zaq.widget.ready") {
            clearTimeout(timer); window.removeEventListener("message", listener); resolve(true);
          }
        }
        window.addEventListener("message", listener);
        iframe.contentWindow!.postMessage({ type: "zaq.widget.ready.request" }, "http://127.0.0.1:4020");
      }))).toBe(true);
      await page.frames().find(frame => frame.url().includes("/widget/theme-dark"))!.evaluate(() => {
        (window as any).attachmentMarker = "already-loaded";
      });
    }
    await page.addScriptTag({ url: "http://127.0.0.1:4020/web_widget/assets/embed.js" });
    if (timing === "before") {
      await page.evaluate(() => {
        (window as any).initialization = (window as any).zaq.widget.init({ user_id: "embed-user" });
      });
      releaseFrame();
      await page.evaluate(() => (window as any).initialization);
    } else {
      await expect(widget.locator(".zaq-widget")).toHaveCount(0);
      expect(await page.evaluate(async () => {
        try { await (window as any).zaq.widget.init({ user_id: "" }); return false; }
        catch { return true; }
      })).toBe(true);
      await expect(widget.locator(".zaq-widget")).toHaveCount(0);
      await page.evaluate(() => (window as any).zaq.widget.init({ user_id: "embed-user" }));
      expect(await page.frames().find(frame => frame.url().includes("/widget/theme-dark"))!.evaluate(() => (window as any).attachmentMarker)).toBe("already-loaded");
    }
    const iframe = page.locator("#zaq-widget");
    await expect(iframe).toHaveAttribute("title", "ZAQ widget");
    await expect(iframe).toHaveCSS("position", "fixed");
    await expect(iframe).toHaveCSS("color-scheme", "light dark");
    await page.evaluate(() => (window as any).zaq.widget.updateSettings({ theme: "dark", language: "fr" }));
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-theme", "dark");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await expect(input).toHaveAttribute("placeholder", "Posez une question…");
    await input.fill("hello"); await input.press("Enter");
    await expect(page.locator("html")).toHaveCSS("overflow", "hidden");
    await expect.poll(() => iframe.evaluate(el => el.style.height)).toBe("100dvh");
    await widget.getByRole("button", { name: "Fermer la discussion", exact: true }).click();
    await expect(page.locator("html")).toHaveCSS("overflow", "auto");
    await expect.poll(() => iframe.evaluate(el => parseFloat(el.style.height))).toBeLessThanOrEqual(260);
    await page.evaluate(() => window.postMessage({ type: "zaq.widget.resize", mode: "conversation" }, "*"));
    await expect(page.locator("html")).toHaveCSS("overflow", "auto");
    await page.evaluate(() => (window as any).zaq.widget.dispose());
    await expect(iframe).not.toHaveAttribute("style");
    await expect(iframe).not.toHaveAttribute("title");
  });
}
