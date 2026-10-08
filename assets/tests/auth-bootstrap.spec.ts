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
