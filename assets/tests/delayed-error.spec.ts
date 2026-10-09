import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

async function mountWidget(page: Page, request: APIRequestContext) {
  const { installation_script } = await (await request.get("http://127.0.0.1:4021/identity")).json();
  await page.goto("/widget/missing");
  await page.evaluate(async ({ installation_script }) => {
    const source = new DOMParser().parseFromString(installation_script, "text/html").querySelector("script")!;
    const script = document.createElement("script");
    for (const attribute of source.attributes) script.setAttribute(attribute.name, attribute.value);
    await new Promise<void>((resolve, reject) => {
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Loader failed"));
      document.body.append(script);
    });
    const frame = document.getElementById("zaq-widget")!;
    frame.dataset.renewals = "0";
    frame.addEventListener("zaq:authentication-required", () => {
      frame.dataset.renewals = String(Number(frame.dataset.renewals) + 1);
    });
  }, { installation_script });

  const widget = page.frameLocator("#zaq-widget");
  await expect(widget.locator("#widget-state")).toBeAttached();
  const bootstrap = await (await request.get("http://127.0.0.1:4021/identity")).json();
  const claims = JSON.parse(Buffer.from(bootstrap.identity_token.split(".")[1], "base64url").toString());
  expect(claims.exp - claims.iat).toBe(300);
  await page.evaluate(identity_token => window.zaq.widget.init({ identity_token }), bootstrap.identity_token);
  return widget;
}

test("displays the mock error returned after three seconds", async ({ page, request }) => {
  const widget = await mountWidget(page, request);
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("delayed error");
  await input.press("Enter");
  await expect(widget.getByText("delayed error", { exact: true })).toBeVisible();
  const error = widget.getByText("The mock failed after three seconds", { exact: true });
  await expect(error).toHaveCount(0);
  await expect(error).toBeVisible({ timeout: 6000 });
  await expect(page.locator("#zaq-widget")).toHaveAttribute("data-renewals", "0");
});
