import { expect, test } from "@playwright/test";

for (const theme of ["light", "dark"]) {
  for (const language of ["en", "ar"]) {
    test(`ZAQ signature is visible in ${theme} ${language} launcher and conversation`, async ({ page, context }) => {
      await page.setViewportSize({ width: 390, height: 844 });
      await page.goto(`/widget-demo?theme=${theme}&language=${language}`);
      const frame = page.frameLocator("#zaq-widget");
      const signature = frame.getByRole("link", { name: "Powered by ZAQ.AI", exact: true });
      await expect(signature).toBeVisible();
      await expect(signature).toHaveAttribute("href", "https://www.zaq.ai/open-source");
      await expect(signature).toHaveAttribute("target", "_blank");
      await expect(signature).toHaveAttribute("rel", "noopener noreferrer");
      await expect(signature).toHaveCSS("direction", "ltr");
      await expect.poll(async () => {
        const outer = (await page.locator("#zaq-widget").boundingBox())!;
        const link = (await signature.boundingBox())!;
        return link.y >= outer.y && link.y + link.height <= outer.y + outer.height;
      }).toBe(true);
      const input = frame.getByRole("textbox", { name: language === "ar" ? "الرسالة" : "Message", exact: true });
      await input.fill("hello"); await input.press("Enter");
      await expect(frame.locator(".zaq-widget")).toHaveAttribute("data-mode", "conversation");
      const header = frame.locator(".zaq-widget-header");
      await expect(header.locator("h1, p, .zaq-assistant-mark, .zaq-header-identity")).toHaveCount(0);
      await expect(header).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
      await expect(header).toHaveCSS("border-bottom-width", "0px");
      await expect(header.getByRole("button", { name: language === "ar" ? "إغلاق المحادثة" : "Close chat", exact: true })).toBeVisible();
      await expect(signature).toBeVisible();
      await input.fill("Keep my draft");
      await context.route("https://www.zaq.ai/open-source", route => route.fulfill({ contentType: "text/html", body: "<h1>ZAQ open source</h1>" }));
      const popupPromise = page.waitForEvent("popup");
      await signature.click();
      const popup = await popupPromise;
      await expect(popup).toHaveURL("https://www.zaq.ai/open-source");
      await popup.close();
      await expect(input).toHaveValue("Keep my draft");
      await frame.getByRole("button", { name: language === "ar" ? "إغلاق المحادثة" : "Close chat", exact: true }).click();
      await expect(signature).toBeVisible();
    });
  }
}
