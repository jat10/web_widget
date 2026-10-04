import { expect, test } from "@playwright/test";

for (const scenario of ["hello", "search", "research", "fail"]) {
  test(`mock ${scenario} renders protocol responses through PubSub`, async ({ page }, testInfo) => {
    await page.goto("/widget-demo");
    const widget = page.frameLocator("#zaq-widget");
    const input = widget.getByRole("textbox", { name: "Message", exact: true });
    await input.fill(scenario);
    await input.press("Enter");
    await expect(widget.getByRole("button", { name: "Send message" })).toBeDisabled();
    await expect(widget.getByText("Assistant is working…")).toBeVisible();
    await expect(widget.locator(".zaq-working")).toBeVisible();
    if (scenario === "hello") {
      await expect(widget.locator(".zaq-answer-content")).toHaveText("Hello! How can I help you today?");
      await expect(widget.locator(".zaq-response-step")).toHaveCount(0);
    } else if (scenario === "research") {
      const steps = widget.locator('.zaq-response-step[data-kind="tool_call"]');
      await expect(steps).toHaveCount(2);
      await expect(steps.first()).toHaveAttribute("data-status", "running");
      await expect(widget.locator(".zaq-activity-toggle")).toHaveAttribute("aria-expanded", "true");
      await expect(steps.first()).toHaveAttribute("data-status", "complete");
      await expect(steps.last()).toHaveAttribute("data-status", "complete");
      await expect(steps).toHaveCount(2);
    } else if (scenario === "fail") {
      await expect(widget.locator('.zaq-response-step[data-kind="tool_call"]')).toHaveAttribute("data-status", "failed");
      await expect(widget.getByRole("alert")).toContainText("Unable to complete this response");
      await expect(widget.locator(".zaq-tool-output")).toBeVisible();
      await expect(widget.locator(".zaq-activity-toggle")).toHaveAttribute("aria-expanded", "true");
    } else {
      await expect(widget.locator('.zaq-response-step[data-kind="tool_call"]')).toHaveAttribute("data-status", "running");
      await expect(widget.locator('.zaq-response-step[data-kind="tool_result"]')).toHaveCount(1);
      await expect(widget.locator('.zaq-answer-content')).toContainText("prototype response");
    }
    await expect(widget.getByRole("button", { name: "Send message" })).toHaveText("Send");
    await expect(widget.getByText("Assistant is working…")).toHaveCount(0);
    await expect(widget.locator(".zaq-working, .zaq-spinner")).toHaveCount(0);
    await expect(widget.locator('[data-streaming="true"]')).toHaveCount(0);
    if (scenario === "research" || scenario === "search") {
      const activity = widget.locator(".zaq-activity-toggle");
      await expect(activity).toHaveAttribute("aria-expanded", "false");
      await expect(widget.locator(".zaq-activity-steps")).toBeHidden();
      await activity.focus();
      await page.keyboard.press("Enter");
      await expect(activity).toHaveAttribute("aria-expanded", "true");
      const result = widget.locator(".zaq-response-step").last();
      await result.locator("summary").click();
      await expect(result.locator(".zaq-tool-output")).toBeVisible();
      await expect(result.locator(".zaq-tool-output")).toContainText(scenario === "research" ? "Two mock sources reviewed." : "A mock result for UI testing.");
      await page.screenshot({ path: testInfo.outputPath(`${scenario}-activity.png`) });
      await activity.click();
      await expect(widget.locator(".zaq-activity-steps")).toBeHidden();
    }
    if (scenario === "fail") {
      await page.screenshot({ path: testInfo.outputPath("failure.png") });
      await input.fill("hello");
      await expect(widget.getByRole("button", { name: "Send message" })).toBeEnabled();
      await input.press("Enter");
      await expect(widget.locator('[data-role="assistant"]').last()).toContainText("Hello! How can I help you today?");
    }
  });
}

test("tool activity and results fit a mobile conversation", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/widget-demo");
  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("research");
  await input.press("Enter");
  const activity = widget.locator(".zaq-activity-toggle");
  await expect(activity).toHaveAttribute("aria-expanded", "false");
  await activity.click();
  await widget.locator(".zaq-response-step").last().locator("summary").click();
  await expect(widget.locator(".zaq-tool-output").last()).toBeVisible();
  expect(await widget.locator(".zaq-thread").evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  const composer = await widget.locator(".zaq-composer").boundingBox();
  expect(composer!.y + composer!.height).toBeLessThanOrEqual(844);
  await page.screenshot({ path: testInfo.outputPath("mobile-activity.png") });
});
