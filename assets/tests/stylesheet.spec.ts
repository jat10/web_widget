import { expect, test } from "@playwright/test";

test("script stylesheet reaches the cross-origin iframe, survives reload, and resets on remount", async ({ page }) => {
  await page.route("http://127.0.0.1:4019/brand.css", route => route.fulfill({
    contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }",
  }));
  await page.goto("/widget/missing");
  await page.evaluate(() => new Promise<void>(resolve => {
    const div = document.createElement("div");
    div.id = "chat";
    div.style.height = "600px";
    document.body.append(div);
    const script = document.createElement("script");
    script.src = "http://127.0.0.1:4020/web_widget/assets/embed.js";
    script.dataset.widgetId = "42";
    script.setAttribute("iframe-location-id", "#chat");
    script.setAttribute("stylesheet-url", "/brand.css");
    script.onload = () => resolve();
    document.body.append(script);
  }));
  await page.evaluate(() => window.zaq.widget.init({ user_id: "css-user" }));
  const widget = page.frameLocator("#chat > iframe");
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  const link = widget.locator("#zaq-widget-stylesheet");
  await expect(link).toHaveAttribute("href", "http://127.0.0.1:4019/brand.css");
  // Repeated readiness must not accumulate links or fetch a different URL.
  await page.evaluate(() => window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", "#chat", "/brand.css"));
  await expect(link).toHaveCount(1);
  await page.frames().find(frame => frame.url().endsWith("/widget/42"))!.evaluate(() => location.reload());
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  await expect(link).toHaveCount(1);
  await page.evaluate(async () => {
    window.zaq.widget.dispose();
    window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", "#chat");
    await window.zaq.widget.init({ user_id: "css-user" });
  });
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await expect(link).toHaveCount(0);
});

test("public ready waits for a stylesheet delivered during the presentation handshake", async ({ page }) => {
  let stylesheetRequested = false;
  let releaseStylesheet: (() => void) | undefined;
  await page.route("**/delayed-brand.css", async route => {
    stylesheetRequested = true;
    await new Promise<void>(resolve => { releaseStylesheet = resolve; });
    await route.fulfill({ contentType: "text/css", body: ":root { --zaq-widget-composer-background: #302640; }" });
  });
  await page.goto("/widget/missing");
  await page.evaluate(() => {
    (window as any).readyCount = 0;
    const iframe = document.createElement("iframe");
    iframe.src = "http://127.0.0.1:4020/widget/42";
    window.addEventListener("message", event => {
      if (event.source !== iframe.contentWindow || event.origin !== "http://127.0.0.1:4020") return;
      if (event.data?.type === "zaq.widget.bootstrap.ready") {
        window.setTimeout(() => iframe.contentWindow?.postMessage({
          type: "zaq.widget.stylesheet", url: "http://127.0.0.1:4019/delayed-brand.css",
        }, "http://127.0.0.1:4020"), 30);
      }
      if (event.data?.type === "zaq.widget.ready") (window as any).readyCount++;
    });
    document.body.append(iframe);
  });
  await expect.poll(() => stylesheetRequested).toBe(true);
  try {
    await page.waitForTimeout(180);
    expect(await page.evaluate(() => (window as any).readyCount)).toBe(0);
  } finally {
    releaseStylesheet?.();
  }
  await expect.poll(() => page.evaluate(() => (window as any).readyCount)).toBe(1);
});

test("invalid stylesheet attributes fail before mounting", async ({ page }) => {
  await page.goto("/widget/missing");
  await page.addScriptTag({ url: "http://127.0.0.1:4020/web_widget/assets/embed.js" });
  for (const url of ["", "javascript:alert(1)", "data:text/css,body{}", "https://user:pass@example.com/style.css", "https://exa mple.com/a.css"]) {
    expect(await page.evaluate(url => {
      try { window.zaq.widget.mount("http://127.0.0.1:4020/widget/42", undefined, url); return false; }
      catch { return true; }
    }, url)).toBe(true);
  }
  await expect(page.locator("iframe")).toHaveCount(0);
});

test("runtime config is ignored and iframe rejects invalid or forged stylesheet messages", async ({ page }) => {
  await page.goto("/widget-demo?widget_id=theme-custom");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator(".zaq-composer")).toBeVisible();
  await expect(widget.locator('link[href*="custom-widget.css"]')).toHaveCount(0);
  const frame = page.frames().find(frame => frame.url().includes("/widget/theme-custom"))!;
  await frame.evaluate(() => {
    for (const event of [
      { source: window, origin: "http://127.0.0.1:4019", url: "https://example.com/forged.css" },
      { source: window.parent, origin: "https://untrusted.example", url: "https://example.com/forged.css" },
      { source: window.parent, origin: "http://127.0.0.1:4019", url: "javascript:alert(1)" },
    ]) {
      window.dispatchEvent(new MessageEvent("message", {
        source: event.source, origin: event.origin, data: { type: "zaq.widget.stylesheet", url: event.url },
      }));
    }
  });
  await expect(widget.locator("#zaq-widget-stylesheet")).toHaveCount(0);
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(255, 255, 255)");
});
