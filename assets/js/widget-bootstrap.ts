import { stylesheetURL } from "./widget-stylesheet";

type Handler = (event: MessageEvent) => void;

const fragment = new URLSearchParams(window.location.hash.slice(1));
let identityToken = fragment.get("identity_token");
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

export function waitForStylesheet(): Promise<void> {
  if (stylesheetPending) return stylesheetPending;
  // The parent may omit stylesheet-url. Its bootstrap message arrives promptly
  // after bootstrap.ready; a short wait keeps public readiness ordered.
  return new Promise(resolve => window.setTimeout(resolve, 100));
}

function applyStylesheet(value: unknown) {
  let url: string | null;
  try {
    url = value === null ? null : stylesheetURL(value);
  } catch {
    postToParent("zaq.widget.stylesheet.error", { reason: "invalid_url" });
    return;
  }
  const existing = document.getElementById("zaq-widget-stylesheet") as HTMLLinkElement | null;
  if (url === null) {
    existing?.remove();
    stylesheetPending = Promise.resolve();
    return;
  }
  if (existing?.href === url) {
    stylesheetPending = Promise.resolve();
    return;
  }
  const link = existing || document.createElement("link");
  link.id = "zaq-widget-stylesheet";
  link.rel = "stylesheet";
  stylesheetPending = new Promise(resolve => {
    const finish = () => { window.clearTimeout(timer); resolve(); };
    const timer = window.setTimeout(finish, 3_000);
    link.addEventListener("load", finish, { once: true });
    link.addEventListener("error", finish, { once: true });
  });
  link.href = url;
  if (!existing) document.head.append(link);
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
  if (!["zaq.widget.connect", "zaq.widget.init", "zaq.widget.settings.update", "zaq.widget.settings.get", "zaq.widget.auth.status"].includes(data?.type)) return;
  if (handler) handler(event);
  else if (queued.length < 20) queued.push(event);
});
