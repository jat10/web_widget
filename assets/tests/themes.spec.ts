import { expect, test } from "@playwright/test";

for (const theme of ["light", "dark"] as const) {
  test(`${theme} input and launcher surroundings stay transparent`, async ({ page }) => {
    await page.goto(`/widget-demo?theme=${theme}`);
    const iframe = page.locator("#zaq-widget");
    const widget = page.frameLocator("#zaq-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    const composer = widget.locator(".zaq-composer");
    await expect(input).toBeVisible();
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-theme", theme);
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-mode", "launcher");
    for (const selector of ["html", "body", ".zaq-widget", ".zaq-widget-footer"]) {
      await expect(widget.locator(selector)).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    }
    await expect(input).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    await expect(input).toHaveCSS("background-image", "none");

    // Remove the intentional shadow so pixels outside the rounded corner must
    // match the parent page exactly, including the browser's iframe canvas.
    await composer.evaluate(el => { el.style.boxShadow = "none"; });
    for (const parentScheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme: parentScheme });
      await page.evaluate(scheme => { document.documentElement.style.colorScheme = scheme; }, parentScheme);
      const box = (await composer.boundingBox())!;
      const clip = { x: box.x + 1, y: box.y + 1, width: 2, height: 2 };
      const actual = await page.screenshot({ clip });
      await iframe.evaluate(el => { el.style.visibility = "hidden"; });
      const underlyingPage = await page.screenshot({ clip });
      await iframe.evaluate(el => { el.style.visibility = "visible"; });
      expect(actual.equals(underlyingPage)).toBe(true);
    }

    await input.fill("hello");
    await expect(input).toBeFocused();
    await expect(input).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    await input.press("Enter");
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-mode", "conversation");
    await expect(input).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  });

  test(`${theme} stays fixed when browser appearance changes`, async ({ page }, testInfo) => {
    await page.emulateMedia({ colorScheme: theme === "light" ? "dark" : "light" });
    await page.goto(`/widget-demo?widget_id=theme-${theme}&theme=${theme}`);
    const widget = page.frameLocator("#zaq-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await expect(input).toBeVisible();
    await expect(widget.locator("html")).not.toHaveAttribute("data-widget-theme");
    // A dark iframe canvas becomes opaque over a light parent, even with transparent CSS.
    await expect(widget.locator("html")).toHaveCSS("color-scheme", "light dark");
    await expect(widget.locator(".zaq-widget")).toHaveCSS("color-scheme", theme);
    const surface = theme === "dark" ? "rgb(13, 20, 28)" : "rgb(255, 255, 255)";
    await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", surface);
    await expect(widget.locator("body")).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
    await input.fill("fail");
    await input.press("Enter");
    await expect(widget.locator(".zaq-response-error")).toBeVisible();
    await expect(widget.locator(".zaq-widget")).toHaveCSS("color", theme === "dark" ? "rgb(243, 245, 247)" : "rgb(12, 19, 36)");
    await expect(widget.locator(".zaq-message-user")).toHaveCSS("background-color", theme === "dark" ? "rgb(31, 43, 53)" : "rgb(226, 232, 240)");
    await expect(widget.locator(".zaq-composer-send")).toHaveCSS("background-color", theme === "dark" ? "rgb(10, 173, 202)" : "rgb(2, 117, 137)");
    await expect(widget.locator(".zaq-widget")).toHaveCSS("background-color", theme === "dark" ? "rgb(4, 11, 18)" : "rgb(250, 250, 250)");
    await expect(widget.locator(".zaq-response-error")).toHaveCSS("color", theme === "dark" ? "rgb(255, 107, 130)" : "rgb(183, 0, 48)");
    await page.emulateMedia({ colorScheme: theme });
    await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", surface);
    await page.screenshot({ path: testInfo.outputPath(`${theme}-theme.png`) });
    await widget.getByRole("button", { name: "Close chat", exact: true }).click();
    await expect(widget.locator(".zaq-widget")).toHaveAttribute("data-mode", "launcher");
    await expect(widget.getByRole("button", { name: "Open conversation" })).toBeVisible();
    const iframe = page.locator("#zaq-widget");
    for (const parentScheme of ["light", "dark"]) {
      await page.evaluate(scheme => { document.documentElement.style.colorScheme = scheme; }, parentScheme);
      const box = (await iframe.boundingBox())!;
      const clip = { x: box.x + 2, y: box.y + 2, width: 3, height: 3 };
      const actual = await page.screenshot({ clip });
      await iframe.evaluate(el => { el.style.visibility = "hidden"; });
      const underlyingPage = await page.screenshot({ clip });
      await iframe.evaluate(el => { el.style.visibility = "visible"; });
      expect(actual.equals(underlyingPage)).toBe(true);
    }
    await page.screenshot({ path: testInfo.outputPath(`${theme}-launcher.png`) });
  });
}

test("default auto follows browser changes in launcher and conversation", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/widget-demo");
  const widget = page.frameLocator("#zaq-widget");
  const composer = widget.locator(".zaq-composer");
  await expect(composer).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await expect(widget.locator("html")).not.toHaveAttribute("data-widget-theme");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(composer).toHaveCSS("background-color", "rgb(13, 20, 28)");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("hello");
  await input.press("Enter");
  await expect(widget.locator(".zaq-widget")).toHaveCSS("background-color", "rgb(4, 11, 18)");
  await page.emulateMedia({ colorScheme: "light" });
  await expect(widget.locator(".zaq-widget")).toHaveCSS("background-color", "rgb(250, 250, 250)");
});

test("host stylesheet overrides theme defaults even before the React CSS loads", async ({ page }) => {
  await page.route("**/custom-widget.css", route => route.fulfill({
    contentType: "text/css",
    body: ":root { --zaq-widget-primary: #7356c7; --zaq-widget-composer-background: #302640; --zaq-widget-radius: 12px; }"
  }));
  await page.goto("/widget-demo?widget_id=theme-custom");
  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator('link[href="/custom-widget.css"]')).toHaveCount(1);
  await expect(widget.locator(".zaq-composer")).toHaveCSS("background-color", "rgb(48, 38, 64)");
  await expect(widget.locator(".zaq-composer")).toHaveCSS("border-radius", "12px");
  await expect(widget.locator(".zaq-composer-send")).toHaveCSS("background-color", "rgb(115, 86, 199)");
});

test("unavailable custom stylesheet retains the built-in theme", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.route("**/custom-widget.css", route => route.fulfill({ status: 404, body: "" }));
  await page.goto("/widget-demo?widget_id=theme-custom");
  await expect(page.frameLocator("#zaq-widget").locator(".zaq-composer")).toHaveCSS("background-color", "rgb(13, 20, 28)");
});
