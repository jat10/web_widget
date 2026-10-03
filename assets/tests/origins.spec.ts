import { expect, test } from "@playwright/test";

test("an explicitly allowed cross-origin parent can initialize and use the widget", async ({ page }) => {
  await page.goto("/widget/missing");
  await page.evaluate(() => {
    const frame = document.createElement("iframe");
    frame.id = "origin-widget";
    window.addEventListener("message", event => {
      if (event.source === frame.contentWindow && event.origin === "http://127.0.0.1:4020" && event.data?.type === "zaq.widget.ready") {
        frame.contentWindow!.postMessage({ type: "zaq.widget.init", user_id: "cross-origin-user" }, event.origin);
      }
    });
    frame.src = "http://127.0.0.1:4020/widget/cross-origin";
    document.body.append(frame);
  });
  const widget = page.frameLocator("#origin-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await expect(input).toBeVisible();
  await input.fill("Allowed parent");
  await input.press("Enter");
  await expect(widget.locator('[data-role="assistant"]')).toContainText("prototype response");
});

for (const widgetId of ["cross-origin", "no-origins", "empty-origins", "missing"]) {
  test(`browser blocks framing ${widgetId} on an unlisted same-origin parent`, async ({ page }) => {
    const violations: string[] = [];
    page.on("console", message => {
      if (message.text().includes("frame-ancestors")) violations.push(message.text());
    });
    await page.goto("http://127.0.0.1:4020/widget/missing");
    await page.evaluate(widgetId => {
      const frame = document.createElement("iframe");
      frame.id = "blocked-widget";
      frame.src = `/widget/${widgetId}`;
      document.body.append(frame);
    }, widgetId);
    await expect.poll(() => violations.length).toBeGreaterThan(0);
    expect(page.frames().some(frame => frame.url().endsWith(`/widget/${widgetId}`) && frame !== page.mainFrame())).toBe(false);
  });
}
