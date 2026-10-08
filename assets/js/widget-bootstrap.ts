import { stylesheetURL } from "./widget-stylesheet";

type Handler = (event: MessageEvent) => void;

const fragment = new URLSearchParams(window.location.hash.slice(1));
let identityToken = fragment.get("identity_token");
let selectedConversationId: string | null = null;
if (identityToken !== null) {
  fragment.delete("identity_token");
  const rest = fragment.toString();
  window.history.replaceState(
    window.history.state,
    "",
    window.location.pathname + window.location.search + (rest ? `#${rest}` : ""),
  );
}

let handler: Handler | undefined;
let publicReady = false;
let parentOrigin: string | undefined;
let queued: MessageEvent[] = [];
let stylesheetPending: Promise<void> | undefined;
let settleStylesheet: (() => void) | undefined;
let stylesheetReceived = false;
let stylesheetDelivered: (() => void) | undefined;
const stylesheetSignal = new Promise<void>(resolve => { stylesheetDelivered = resolve; });

const allowedOrigins = (): string[] => {
  try {
    const raw = document.getElementById("widget-context")?.dataset.allowedDomains;
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
};

const allowed = (event: MessageEvent) =>
  window.parent !== window &&
  event.source === window.parent &&
  allowedOrigins().includes(event.origin);

export const currentIdentityToken = () => identityToken;
export const acceptIdentityToken = (token: string) => { identityToken = token; };
export const currentConversationId = () => selectedConversationId;
export const acceptConversationId = (id: string) => { selectedConversationId = id; };
export const currentParentOrigin = () => parentOrigin;

export function postToParent(type: string, detail: object = {}) {
  if (window.parent === window) return;
  for (const origin of allowedOrigins()) {
    window.parent.postMessage({ type, ...detail }, origin);
  }
}

export function registerWidgetHandler(next: Handler) {
  handler = next;
  postToParent("zaq.widget.bootstrap.ready");
  for (const event of queued) next(event);
  queued = [];
}

export function unregisterWidgetHandler(current: Handler) {
  if (handler === current) handler = undefined;
}

export function setPublicReady(ready: boolean) {
  if (publicReady === ready) return;
  publicReady = ready;
  if (ready) postToParent("zaq.widget.ready");
}

export async function waitForStylesheet(): Promise<void> {
  if (!stylesheetReceived) {
    // The SDK always sends a stylesheet decision, including null when omitted.
    // Keep a fallback for parents that only use the manual iframe protocol.
    await Promise.race([
      stylesheetSignal,
      new Promise<void>(resolve => window.setTimeout(resolve, 1_000)),
    ]);
  }
  // Replacement settles obsolete waiters; follow the active decision before ready.
  let pending: Promise<void> | undefined;
  do {
    pending = stylesheetPending;
    await pending;
  } while (pending !== stylesheetPending);
}

function applyStylesheet(value: unknown) {
  stylesheetReceived = true;
  stylesheetDelivered?.();
  let url: string | null;
  try {
    url = value === null ? null : stylesheetURL(value);
  } catch {
    postToParent("zaq.widget.stylesheet.error", { reason: "invalid_url" });
    return;
  }
  const existing = document.getElementById("zaq-widget-stylesheet") as HTMLLinkElement | null;
  if (url === null) {
    settleStylesheet?.();
    existing?.remove();
    stylesheetPending = Promise.resolve();
    return;
  }
  if (existing?.href === url) return;
  settleStylesheet?.();
  existing?.remove();
  const link = document.createElement("link");
  link.id = "zaq-widget-stylesheet";
  link.rel = "stylesheet";
  stylesheetPending = new Promise(resolve => {
    const finish = () => {
      window.clearTimeout(timer);
      link.removeEventListener("load", finish);
      link.removeEventListener("error", finish);
      resolve();
    };
    settleStylesheet = finish;
    const timer = window.setTimeout(finish, 3_000);
    link.addEventListener("load", finish, { once: true });
    link.addEventListener("error", finish, { once: true });
  });
  link.href = url;
  document.head.append(link);
}

window.addEventListener("message", event => {
  if (!allowed(event)) return;
  parentOrigin = event.origin;
  const data = event.data;
  if (data?.type === "zaq.widget.ready.request") {
    postToParent("zaq.widget.bootstrap.ready");
    if (publicReady) postToParent("zaq.widget.ready");
    return;
  }
  if (data?.type === "zaq.widget.stylesheet") {
    applyStylesheet(data.url);
    return;
  }
  if (!["zaq.widget.connect", "zaq.widget.init", "zaq.widget.context.update", "zaq.widget.settings.update", "zaq.widget.settings.get", "zaq.widget.auth.status"].includes(data?.type)) return;
  if (handler) handler(event);
  else if (queued.length < 20) queued.push(event);
});
