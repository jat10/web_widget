import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

async function mountWidget(page: Page, request: APIRequestContext, renew: boolean) {
  // Proxy the test signing endpoint through the parent page's origin.
  await page.route("**/test-widget-identity*", async route => {
    const query = new URL(route.request().url()).search;
    const response = await request.get(`http://127.0.0.1:4021/identity${query}`);
    await route.fulfill({ response });
  });
  const { installation_script } = await (await request.get("http://127.0.0.1:4021/identity")).json();
  await page.goto("/widget/missing");
  await page.evaluate(async ({ installation_script, renew }) => {
    const source = new DOMParser().parseFromString(installation_script, "text/html").querySelector("script")!;
    const script = document.createElement("script");
    for (const attribute of source.attributes) script.setAttribute(attribute.name, attribute.value);
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Loader failed"));
      document.body.append(script);
    });
    const frame = document.getElementById("zaq-widget")!;
    frame.addEventListener("zaq:conversation", (event: Event) => {
      frame.dataset.conversationId = (event as CustomEvent).detail.conversation_id;
    });
    frame.dataset.renewals = "0";
    frame.addEventListener("zaq:authentication-required", () => {
      frame.dataset.renewals = String(Number(frame.dataset.renewals) + 1);
      if (!renew) return;
      void (async () => {
        if (!frame.dataset.conversationId) throw new Error("Expired before the message was accepted");
        const response = await fetch(`/test-widget-identity?conversation_id=${encodeURIComponent(frame.dataset.conversationId)}`);
        if (!response.ok) throw new Error("Token renewal failed");
        const { identity_token } = await response.json();
        await window.zaq.widget.init({ identity_token });
        frame.dataset.renewed = "true";
      })().catch(error => { frame.dataset.renewalError = String(error); });
    });
  }, { installation_script, renew });

  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-state")).toBeAttached();
  // Mint only once the iframe is mounted so setup does not consume the short TTL.
  const bootstrap = await (await request.get(`http://127.0.0.1:4021/identity${renew ? "?short=true" : ""}`)).json();
  const claims = JSON.parse(Buffer.from(bootstrap.identity_token.split(".")[1], "base64url").toString());
  expect(claims.exp - claims.iat).toBe(renew ? 3 : 300);
  await page.evaluate(identity_token => window.zaq.widget.init({ identity_token }), bootstrap.identity_token);
  return widget;
}

test("receives a five-second reply after renewing a three-second JWT", async ({ page, request }) => {
  const widget = await mountWidget(page, request, true);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("delayed answer");
  await input.press("Enter");
  const frame = page.locator("#zaq-widget");
  await expect(frame).toHaveAttribute("data-conversation-id", "conversation-1");
  await expect(widget.getByText("delayed answer", { exact: true })).toBeVisible();
  await expect(frame).toHaveAttribute("data-renewed", "true", { timeout: 5000 });
  await expect(frame).toHaveAttribute("data-renewals", "1");
  await expect(frame).not.toHaveAttribute("data-renewal-error");
  await expect(widget.getByText("Answer after five seconds", { exact: true })).toHaveCount(0);
  await expect(widget.getByText("Answer after five seconds", { exact: true })).toBeVisible({ timeout: 7000 });
});

test("displays the mock error returned after three seconds", async ({ page, request }) => {
  const widget = await mountWidget(page, request, false);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("delayed error");
  await input.press("Enter");
  await expect(widget.getByText("delayed error", { exact: true })).toBeVisible();
  const error = widget.getByText("The mock failed after three seconds", { exact: true });
  await expect(error).toHaveCount(0);
  await expect(error).toBeVisible({ timeout: 6000 });
  await expect(page.locator("#zaq-widget")).toHaveAttribute("data-renewals", "0");
});
