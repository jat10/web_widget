# Add the ZAQ widget to menuflex.app

The Menuflex website embeds the widget in an iframe, provides an anonymous visitor ID, and controls language and theme. ZAQ hosts the widget and handles messages, responses, and conversation storage. Menuflex does not need a user account system or its own chat WebSocket.

## 1. Get the deployment details from the ZAQ team

Ask for these two URLs:

- **Widget URL:** for example, `https://YOUR-ZAQ-HOST/widget/YOUR-WIDGET-ID`.
- **Embed script URL:** for example, `https://YOUR-ZAQ-HOST/web_widget/assets/embed.js`.

These are placeholders. Use the actual URLs supplied by the ZAQ team; the deployed route prefixes may differ.

The ZAQ team must enable the widget and include `https://menuflex.app` in its `allowed_domains`. Add `https://www.menuflex.app` only if the widget is also embedded there. Development and staging origins need their own entries, including the port when applicable. These entries are exact origins, not page URLs or bare domain names.

Language and theme belong to Menuflex's initialization and runtime settings, not ZAQ's persisted widget configuration.

## 2. Give each anonymous visitor an ID

Generate a random ID once and save it under a Menuflex-specific `localStorage` key. Reuse it when the visitor reopens chat, navigates to another page, or returns in the same browser.

- Do not generate a new ID for each message or each opening of the chat.
- Do not use a shared constant such as `guest` for every visitor.
- Clearing browser storage, using another browser, or another device produces a different identity.
- This is an anonymous browser identifier, not proof of a person's identity. ZAQ remains responsible for validating access.

The example below falls back to an in-memory ID if storage is unavailable. That fallback lasts until the parent page reloads. If you deliberately want identity to last only for the tab session, replace `localStorage` with `sessionStorage`.

## 3. Embed and initialize the widget

Place this in the site's shared layout, once per page. Replace both URLs before using it. For a frontend framework, run the JavaScript on the client after the iframe mounts.

The embed script runs on Menuflex and provides `zaq.widget`. It handles readiness, message validation, default iframe styling, resizing, and scroll locking. The chat stays hidden until a valid `user_id` is accepted. The script works whether the iframe finishes loading before or after `init()`.

```html
<iframe src="https://YOUR-ZAQ-HOST/widget/YOUR-WIDGET-ID"
        id="zaq-widget" title="ZAQ widget"></iframe>
<script src="https://YOUR-ZAQ-HOST/web_widget/assets/embed.js"></script>
<script>
  let visitorId;
  try { visitorId = localStorage.getItem("menuflex.zaq.visitor-id"); } catch {}
  if (!visitorId?.trim()) {
    visitorId = `menuflex-anon-${crypto.randomUUID()}`;
    try { localStorage.setItem("menuflex.zaq.visitor-id", visitorId); } catch {}
  }

  zaq.widget.init({
    user_id: visitorId,
    prompt_context: `Website: menuflex.app; page: ${location.pathname}`,
    settings: { theme: "auto", language: "en" },
  }).catch(error => console.error("Could not initialize Menuflex chat", error));
</script>
```

Load the script after the iframe and before calling the API. Do not add `async` or `defer` to this example: the following inline script needs the API to exist. No manual import, readiness listener, resize handler, or iframe styling is required.

`crypto.randomUUID()` runs on HTTPS sites and localhost. Keep one widget mounted in the shared layout during client-side navigation. Before removing its iframe, call `zaq.widget.dispose()` to remove listeners and restore its original inline styles and page scrolling. Disposal does not remove the iframe or reset its identity; use a new iframe document when changing users.

The default placement is fixed at the bottom of the page. Chat expands to the viewport and collapses to the launcher automatically. Existing inline style values are respected initially; height is managed by resize events. For custom layouts or multiple widgets, use the lower-level `createWidgetClient` API documented in README.md. The global API targets one iframe with `id="zaq-widget"`.

## 4. Connect Menuflex's language and theme controls

Set the initial values in `zaq.widget.init()` from the website's preferences. After initialization, use partial updates:

```js
await zaq.widget.updateSettings({ theme: "dark" });
await zaq.widget.updateSettings({ language: "fr" });
await zaq.widget.updateSettings({ theme: "light", language: "ar" });

// Optional: inspect the currently applied settings.
const settings = await zaq.widget.getSettings();
console.log(settings);
```

| Setting | Accepted values | Default |
| --- | --- | --- |
| `theme` | `"auto"`, `"light"`, `"dark"` | `"auto"` |
| `language` | `"en"`, `"fr"`, `"ar"` | `"en"` |

`auto` follows the browser's preferred appearance. Arabic switches the widget UI to right-to-left layout. Language changes translate widget controls; they do not translate existing ZAQ responses or choose the assistant's response language.

Updates preserve messages, drafts, the selected conversation, and replies in progress. They change only the supplied settings. Unsupported keys or values reject the whole update. Use `try/catch` in website event handlers to handle rejected requests. Requests time out after 20 seconds; after an update timeout, inspect settings before retrying because the update may still have reached the widget.

Calling `getSettings()` first is optional. Menuflex decides whether to save preferences and supply them again on the next page load. Use `updateSettings()` for later changes; repeated initialization is not a settings update.

## 5. Understand identity and conversation lifetime

`user_id` identifies the anonymous visitor. `conversation_id` identifies a particular conversation; they are different values.

Start with `conversation_id: null`. Do not invent a conversation ID or reuse the visitor ID as one. To explicitly resume a conversation, use a real conversation ID supplied through your ZAQ integration and authorized for that visitor. Reusing the visitor ID alone does not guarantee that a particular conversation automatically reopens; history availability depends on ZAQ and the widget's conversation configuration.

The client automatically reuses the accepted initialization after reconnects. Changing the visitor identity or bootstrap context requires a fresh iframe document/client. Closing the chat only collapses it; it does not reset identity or end the conversation.

## 6. Validate the integration

- Open menuflex.app: the launcher appears after initialization.
- Send a message: chat expands, ZAQ receives it, and a response appears.
- Close and reopen chat: the conversation and unsent draft remain available.
- Refresh the parent page: `menuflex.zaq.visitor-id` remains the same in local storage.
- Open a separate browser profile: it gets a different visitor ID.
- Switch light/dark/auto and English/French/Arabic while chatting: settings apply without losing the conversation.
- Check the launcher's rounded corners on light and dark pages: the surrounding iframe stays transparent.
- Test Chromium, Firefox, WebKit/Safari, and a narrow mobile viewport.

If initialization fails, check the two deployment URLs, the browser console, and whether the exact Menuflex origin is allowed by ZAQ. If the site uses a Content Security Policy, ensure it permits the deployed embed script and iframe origins. The ZAQ deployment must also permit embedding from Menuflex.
