import { expect, test, type Page, type APIRequestContext } from "@playwright/test";

async function mountSharedWidget(page: Page, request: APIRequestContext) {
  const user = `failure-${crypto.randomUUID()}`;
  await page.route("**/api/widget-token", async route => {
    const issued = await request.get("http://127.0.0.1:4021/identity", { params: { user_id: user } });
    expect(issued.ok()).toBe(true);
    const { identity_token } = await issued.json();
    await route.fulfill({ headers: { "cache-control": "no-store" }, json: { identity_token } });
  });
  await page.goto("/widget/missing");
  await page.evaluate(async () => {
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
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  return widget;
}

test("accepted pre-stream failure renders the host recovery link and permits another send", async ({ page, request }) => {
  const widget = await mountSharedWidget(page, request);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  const portal = "https://people.example.test/credentials?return_to=chat&source=widget";
  const body = `Personal credentials are required. [Open People portal](${portal}) to connect your account.`;
  await input.fill(`pre-stream failure: ${body}`);
  await input.press("Enter");

  const assistant = widget.locator('[data-role="assistant"]');
  const alert = assistant.getByRole("alert");
  await expect(alert).toContainText("Personal credentials are required.");
  await expect(alert.getByRole("link", { name: "Open People portal" })).toHaveAttribute("href", portal);
  await expect(assistant).toHaveCount(1);
  await expect(assistant).toHaveAttribute("data-running", "false");
  await expect(assistant.locator(".zaq-answer-content")).toBeEmpty();
  await expect(assistant).not.toContainText("PRIVATE_TRACE");
  await expect(widget.locator(".zaq-widget-error")).toHaveCount(0);
  await expect(widget.locator(".zaq-header-status, .zaq-working")).toHaveCount(0);
  await expect(input).toHaveValue("");

  // Context routing also intercepts the new tab's first request.
  await page.context().route("https://people.example.test/**", route => route.fulfill({ contentType: "text/html", body: "People portal" }));
  const link = alert.getByRole("link", { name: "Open People portal" });
  await expect(link).toHaveAttribute("target", "_blank");
  await expect(link).toHaveAttribute("rel", "noopener noreferrer");
  const widgetUrl = await widget.locator("body").evaluate(() => location.href);
  const [portalTab] = await Promise.all([
    page.context().waitForEvent("page"),
    link.click(),
  ]);
  await expect(portalTab).toHaveURL(portal);
  await expect(portalTab.locator("body")).toHaveText("People portal");
  expect(await portalTab.evaluate(() => window.opener)).toBeNull();
  expect(await widget.locator("body").evaluate(() => location.href)).toBe(widgetUrl);
  await expect(widget.locator("#widget-context")).toHaveAttribute("data-authorized", "true");
  await expect(alert).toContainText("Personal credentials are required.");

  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await portalTab.close();
});

test("failure Markdown cannot inject HTML or executable links and does not block later replies", async ({ page, request }) => {
  const widget = await mountSharedWidget(page, request);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  const body = [
    "**Safe public explanation** with https://people.example.test/credentials.",
    "[Unsafe script](javascript:alert%281%29)",
    "[Unsafe data](data:text/html,test)",
    '<img src="invalid" onerror="window.failureInjected=true">',
    '<script>window.failureInjected=true</script>',
  ].join("\n\n");
  await input.fill(`pre-stream failure: ${body}`);
  await input.press("Enter");

  const alert = widget.locator('[data-role="assistant"]').getByRole("alert");
  await expect(alert.locator("strong").filter({ hasText: "Safe public explanation" })).toBeVisible();
  await expect(alert.getByRole("link", { name: "https://people.example.test/credentials" })).toHaveAttribute("href", "https://people.example.test/credentials");
  await expect(alert.locator('a[href^="javascript:"], a[href^="data:"], img, script')).toHaveCount(0);
  expect(await alert.evaluate(() => (window as any).failureInjected)).toBeUndefined();
  await expect(widget.locator('[data-role="assistant"]')).not.toContainText("PRIVATE_TRACE");

  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await expect(widget.locator('[data-role="assistant"]')).toHaveCount(2);
});

test("true submission rejection restores the draft without creating a failed assistant", async ({ page, request }) => {
  const widget = await mountSharedWidget(page, request);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("submission rejected");
  await input.press("Enter");
  await expect(widget.locator(".zaq-widget-error")).toHaveText("Unable to complete this request.");
  await expect(input).toHaveValue("submission rejected");
  await expect(widget.locator('[data-role="assistant"]')).toHaveCount(0);
  await expect(widget.locator(".zaq-response-error")).toHaveCount(0);

  await input.fill("instant");
  await input.press("Enter");
  await expect(widget.getByText("Immediate answer", { exact: true })).toBeVisible();
  await expect(widget.locator(".zaq-widget-error")).toHaveCount(0);
});
