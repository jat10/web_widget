import { expect, test } from "@playwright/test";

const locales = [
  { locale: "en", message: "Message", send: "Send message", placeholder: "Ask a question…", today: "Today", yesterday: "Yesterday", close: "Close chat", reopen: "Open conversation", newChat: "New chat", activity: "View response activity", complete: "2 steps completed", invalid: "Enter a message of 1–2000 characters." },
  { locale: "fr", message: "Message", send: "Envoyer le message", placeholder: "Posez une question…", today: "Aujourd’hui", yesterday: "Hier", close: "Fermer la discussion", reopen: "Ouvrir la conversation", newChat: "Nouvelle conversation", activity: "Voir les étapes de la réponse", complete: "2 étapes terminées", invalid: "Saisissez un message de 1 à 2000 caractères." },
  { locale: "ar", message: "الرسالة", send: "إرسال الرسالة", placeholder: "اطرح سؤالًا…", today: "اليوم", yesterday: "أمس", close: "إغلاق المحادثة", reopen: "فتح المحادثة", newChat: "محادثة جديدة", activity: "عرض نشاط الرد", complete: "اكتملت خطوتان", invalid: "أدخل رسالة من حرف واحد إلى 2000 حرف." },
];

for (const labels of locales) {
  test(`${labels.locale} localizes controls, history, activity and validation`, async ({ page }, testInfo) => {
    await page.goto(`/widget-demo?widget_id=locale-${labels.locale}&language=${labels.locale}`);
    const widget = page.frameLocator("#zaq-demo-widget");
    await expect(widget.locator("html")).toHaveAttribute("lang", labels.locale);
    await expect(widget.locator("html")).toHaveAttribute("dir", labels.locale === "ar" ? "rtl" : "ltr");
    const input = widget.getByRole("textbox", { name: labels.message, exact: true });
    await expect(input).toHaveAttribute("placeholder", labels.placeholder);
    await input.fill("research");
    await widget.getByRole("button", { name: labels.send, exact: true }).click();
    await expect(widget.locator(".zaq-activity-toggle")).toContainText(labels.activity);
    await expect(widget.locator(".zaq-activity-toggle")).toContainText(labels.complete);
    if (labels.locale === "ar") {
      const sidebar = (await widget.locator(".zaq-conversations").boundingBox())!;
      const main = (await widget.locator(".zaq-chat-main").boundingBox())!;
      expect(sidebar.x).toBeGreaterThan(main.x);
      await page.screenshot({ path: testInfo.outputPath("arabic-desktop.png") });
    }
    await expect(widget.getByRole("heading", { name: "Host assistant", exact: true })).toBeVisible();
    await widget.getByRole("button", { name: "A weekend outdoors" }).click();
    await expect(widget.locator(".zaq-date-separator")).toHaveText([labels.yesterday, labels.today]);
    const time = widget.locator(".zaq-message-time").first();
    const expected = await time.evaluate((el, locale) => new Date(el.getAttribute("datetime")!).toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" }), labels.locale);
    await expect(time).toHaveText(expected);
    await widget.getByRole("button", { name: labels.newChat, exact: true }).click();
    await expect(widget.locator("[data-role]")).toHaveCount(0);
    await expect(widget.locator(".zaq-empty-chat")).toBeVisible();
    await input.evaluate(el => el.removeAttribute("maxlength"));
    await input.fill("x".repeat(2001));
    await input.press("Enter");
    await expect(widget.getByRole("alert")).toHaveText(labels.invalid);
    await widget.getByRole("button", { name: labels.close, exact: true }).click();
    await expect(widget.getByRole("button", { name: labels.reopen, exact: true })).toBeVisible();
  });
}

test("Arabic mobile layout contains mixed-direction text without overflow", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/widget-demo?widget_id=locale-ar&language=ar");
  const widget = page.frameLocator("#zaq-demo-widget");
  const input = widget.getByRole("textbox", { name: "الرسالة", exact: true });
  const message = "مرحبًا support@example.com https://example.com 123";
  await input.fill(message);
  await input.press("Enter");
  await expect(widget.locator(".zaq-user-content").last()).toHaveText(message);
  await expect(widget.locator(".zaq-user-content").last()).toHaveAttribute("dir", "auto");
  await expect(widget.locator(".zaq-widget")).toHaveCSS("direction", "rtl");
  await expect(widget.locator(".zaq-composer-send")).toHaveText("إرسال");
  await input.fill("سؤال إضافي");
  await expect(widget.locator(".zaq-composer-send")).toBeEnabled();
  expect(await widget.locator("html").evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  const send = (await widget.locator(".zaq-composer-send").boundingBox())!;
  const textbox = (await input.boundingBox())!;
  expect(send.x).toBeLessThan(textbox.x);
  await page.screenshot({ path: testInfo.outputPath("arabic-mobile.png") });
});
