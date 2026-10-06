import { expect, test } from "@playwright/test";

test("assistant host responses render Markdown as semantic HTML", async ({ page, request }, testInfo) => {
  const userId = crypto.randomUUID();
  const markdown = [
    "## Widget setup",
    "",
    "This is **important**. Run `mix test`.",
    "",
    "- First step",
    "- Second step",
    "",
    "Read the [documentation](https://example.com/docs).",
    "",
    "```elixir",
    'IO.puts("Hello")',
    "```",
    "",
    "Markdown response complete.",
  ].join("\n");

  const configured = await request.post(`http://127.0.0.1:4021/sessions/${userId}`, {
    data: { answer: markdown, partial: "", step_kind: "none" },
  });
  expect(configured.ok()).toBe(true);

  await page.goto("/widget/missing");
  await page.addScriptTag({ url: "/web_widget/assets/embed.js" });
  await page.evaluate(async userId => {
    window.zaq.widget.mount(new URL("/widget/e2e", location.href).href);
    await window.zaq.widget.init({ user_id: userId });
  }, userId);

  const widget = page.frameLocator("#zaq-widget");
  const input = widget.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Show the widget setup instructions in Markdown.");
  await input.press("Enter");

  const assistant = widget.locator('[data-role="assistant"]').last();
  const answer = assistant.locator(".zaq-answer-content");
  // Confirm delivery and completion before checking presentation, so transport
  // or streaming failures cannot masquerade as missing Markdown support.
  await expect(answer).toContainText("Markdown response complete.");
  await expect(assistant).toHaveAttribute("data-running", "false");

  await testInfo.attach("assistant-rendered.html", {
    body: await answer.innerHTML(), contentType: "text/html",
  });
  await page.screenshot({ path: testInfo.outputPath("markdown-response.png"), fullPage: true });

  const rendered = await answer.evaluate(element => ({
    heading: element.querySelector("h2")?.textContent ?? null,
    bold: element.querySelector("strong")?.textContent ?? null,
    listItems: [...element.querySelectorAll("ul > li")].map(item => item.textContent),
    link: element.querySelector('a[href="https://example.com/docs"]')?.textContent ?? null,
    inlineCode: element.querySelector("p code")?.textContent ?? null,
    codeBlock: element.querySelector("pre code")?.textContent?.trim() ?? null,
  }));

  expect(rendered).toEqual({
    heading: "Widget setup",
    bold: "important",
    listItems: ["First step", "Second step"],
    link: "documentation",
    inlineCode: "mix test",
    codeBlock: 'IO.puts("Hello")',
  });
});
