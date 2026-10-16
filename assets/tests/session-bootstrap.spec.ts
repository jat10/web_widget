import { expect, test } from "@playwright/test";

for (const failure of ["network", "503"]) {
  test(`initial session heals after prolonged ${failure} failure`, async ({ page }) => {
    let unavailable = true;
    let attempts = 0;
    let sockets = 0;
    page.on("websocket", () => sockets++);
    await page.route("**/widget/theme-dark/session*", route => {
      attempts++;
      if (!unavailable) return route.continue();
      return failure === "network" ? route.abort() : route.fulfill({ status: 503 });
    });
    await page.goto("/widget/theme-dark");
    await expect.poll(() => attempts).toBeGreaterThan(0);
    // Stay unavailable beyond the removed initial-connection deadline.
    await page.waitForTimeout(12_000);
    expect(attempts).toBeGreaterThan(1);
    expect(sockets).toBe(0);
    await expect(page.locator("#widget-session-error")).toBeHidden();
    unavailable = false;
    await expect.poll(() => page.evaluate(() =>
      (window as any).liveSocket?.isConnected() || false), { timeout: 15_000 }).toBe(true);
    await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
    await expect(page.locator("#widget-session-error")).toBeHidden();
  });
}
