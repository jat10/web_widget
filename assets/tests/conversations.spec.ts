import { expect, test } from "@playwright/test";

for (const mobile of [false, true]) {
  test(`multiple conversations show timestamped history ${mobile ? "on mobile" : "on desktop"}`, async ({ page }, testInfo) => {
    if (mobile) await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/widget-demo?widget_id=multi");
    const widget = page.frameLocator("#zaq-demo-widget");
    const sidebar = widget.getByRole("complementary", { name: "Conversations" });
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await expect(input).toBeVisible();
    await expect(page.locator("#zaq-demo-widget")).toHaveAttribute("data-mode", "launcher");
    await expect(sidebar).toHaveCount(0);
    await expect(widget.getByRole("button", { name: "Open conversation" })).toHaveCount(0);
    await input.fill("hello");
    await expect(page.locator("#zaq-demo-widget")).toHaveAttribute("data-mode", "launcher");
    await input.press("Enter");
    await expect(sidebar).toBeVisible();
    await expect(widget.getByRole("button", { name: "Send message" })).toHaveText("Send");
    await expect(sidebar.locator("nav button")).toHaveCount(4);
    await expect(sidebar.getByRole("button", { name: "New chat", exact: true })).toBeVisible();
    const first = sidebar.getByRole("button", { name: "A weekend outdoors" });
    await first.click();
    await expect(first).toHaveAttribute("aria-current", "page");
    await expect(widget.locator("[data-role]")).toHaveCount(4);
    await expect(widget.locator(".zaq-message-time")).toHaveCount(4);
    await expect(widget.locator(".zaq-date-separator")).toHaveText(["Yesterday", "Today"]);
    for (const time of await widget.locator(".zaq-message-time").all()) {
      await expect(time).toHaveAttribute("datetime", /T/);
      await expect(time).not.toHaveText("");
    }
    await sidebar.getByRole("button", { name: "Understanding my bill" }).click();
    await expect(widget.locator("[data-role]")).toHaveCount(6);
    await expect(widget.locator(".zaq-date-separator")).toHaveText(["Yesterday", "Today"]);
    await sidebar.getByRole("button", { name: "Community research" }).click();
    await expect(widget.locator("[data-role]")).toHaveCount(7);
    await expect(widget.locator(".zaq-message-time")).toHaveCount(7);
    await expect(widget.locator(".zaq-date-separator")).toHaveText(["Yesterday", "Today"]);
    expect(await widget.locator(".zaq-widget").evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
    await widget.locator(".zaq-thread").evaluate(el => { el.scrollTop = 0; });
    await page.screenshot({ path: testInfo.outputPath("conversation-history.png") });
    await input.fill("A draft for this conversation");
    await sidebar.getByRole("button", { name: "New chat", exact: true }).click();
    await expect(widget.locator("[data-role]")).toHaveCount(0);
    await expect(input).toHaveValue("");
    await widget.getByRole("button", { name: "Close chat", exact: true }).click();
    await expect(page.locator("#zaq-demo-widget")).toHaveAttribute("data-mode", "launcher");
    await widget.getByRole("button", { name: "Open conversation" }).click();
    await expect(page.locator("#zaq-demo-widget")).toHaveAttribute("data-mode", "conversation");
    await expect(widget.getByText("How can I help?", { exact: true })).toBeVisible();
    await input.fill("hello");
    await input.press("Enter");
    await expect(first).toBeDisabled();
    await expect(widget.locator(".zaq-answer-content")).toHaveText("Hello! How can I help you today?");
    await expect(first).toBeEnabled();
    await expect(sidebar.locator("nav button")).toHaveCount(5);
    await expect(widget.locator(".zaq-message-time")).toHaveCount(2);
    await expect(widget.locator(".zaq-date-separator")).toHaveText(["Today"]);
    await first.click();
    await expect(widget.locator("[data-role]")).toHaveCount(4);
    await sidebar.getByRole("button", { name: "hello", exact: true }).first().click();
    await expect(widget.locator("[data-role]")).toHaveCount(2);
  });
}

test("single conversation is the default", async ({ page }) => {
  await page.goto("/widget-demo");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("hello");
  await input.press("Enter");
  await expect(widget.locator(".zaq-answer-content")).toHaveText("Hello! How can I help you today?");
  await expect(widget.getByRole("complementary", { name: "Conversations" })).toHaveCount(0);
  await expect(widget.locator(".zaq-message-time")).toHaveCount(2);
  await expect(widget.locator(".zaq-date-separator")).toHaveText(["Today"]);
});
