import { createWidgetClient, type WidgetInit, type DemoWidgetInit, type WidgetSettings } from "./widget-client";

function createEmbed() {
  let client: ReturnType<typeof createWidgetClient> | undefined;
  let cleanup: (() => void) | undefined;
  let ownedFrame: HTMLIFrameElement | undefined;
  let mountedFrame: HTMLIFrameElement | undefined;
  let container: HTMLDivElement | undefined;

  function connect() {
    if (client) return client;
    const iframe = mountedFrame || document.getElementById("zaq-widget");
    if (!(iframe instanceof HTMLIFrameElement) || !iframe.getAttribute("src")) {
      throw new Error('Add an iframe with id="zaq-widget" and a widget src before calling zaq.widget.init().');
    }
    const origin = new URL(iframe.src).origin;
    const originalStyle = iframe.getAttribute("style");
    const originalTitle = iframe.getAttribute("title");
    const originalMode = iframe.getAttribute("data-mode");
    const originalOverflow = document.documentElement.style.overflow;
    const defaults = container ? {
      display: "block", position: "static", width: "100%", height: "100%",
      border: "0", background: "transparent", colorScheme: "light dark",
    } : {
      position: "fixed", bottom: "0", left: "0", width: "100%", height: "180px",
      border: "0", background: "transparent", colorScheme: "light dark", zIndex: "1000",
    };
    for (const [key, value] of Object.entries(defaults)) {
      const property = key as keyof typeof defaults;
      if (!iframe.style[property]) iframe.style[property] = value;
    }
    if (!originalTitle) iframe.title = "ZAQ widget";
    const resize = (event: MessageEvent) => {
      if (event.source !== iframe.contentWindow || event.origin !== origin) return;
      const data = event.data;
      if (data?.type !== "zaq.widget.resize") return;
      if (container) {
        if (data.mode === "conversation" || (data.mode === "launcher" && Number.isFinite(data.height))) {
          iframe.dataset.mode = data.mode;
        }
        return;
      }
      if (data.mode === "conversation") {
        iframe.dataset.mode = "conversation";
        iframe.style.height = "100dvh";
        document.documentElement.style.overflow = "hidden";
      } else if (data.mode === "launcher" && Number.isFinite(data.height)) {
        iframe.dataset.mode = "launcher";
        iframe.style.height = `${Math.min(260, Math.max(96, data.height))}px`;
        document.documentElement.style.overflow = originalOverflow;
      }
    };
    window.addEventListener("message", resize);
    cleanup = () => {
      window.removeEventListener("message", resize);
      if (!container) document.documentElement.style.overflow = originalOverflow;
      if (originalStyle === null) iframe.removeAttribute("style");
      else iframe.setAttribute("style", originalStyle);
      if (originalMode === null) iframe.removeAttribute("data-mode");
      else iframe.setAttribute("data-mode", originalMode);
      if (originalTitle === null) iframe.removeAttribute("title");
      else iframe.setAttribute("title", originalTitle);
    };
    try {
      client = createWidgetClient(iframe, iframe.src);
    } catch (error) {
      cleanup();
      cleanup = undefined;
      throw error;
    }
    return client;
  }

  return {
    mount(url: string, selector?: string) {
      const target = new URL(url);
      if (!["https:", "http:"].includes(target.protocol)) throw new Error("Widget URL must use HTTP(S).");
      let destination: HTMLDivElement | undefined;
      if (selector !== undefined) {
        let element: Element | null;
        try { element = document.querySelector(selector); }
        catch { throw new Error("Invalid iframe-location-id selector."); }
        if (!(element instanceof HTMLDivElement)) {
          throw new Error("iframe-location-id must select an existing div.");
        }
        destination = element;
      }
      if (mountedFrame && container !== destination) {
        throw new Error("Widget is already mounted in a different location.");
      }
      const frameId = destination?.id === "zaq-widget" ? "zaq-widget-frame" : "zaq-widget";
      const existing = mountedFrame || document.getElementById(frameId);
      if (existing && (!(existing instanceof HTMLIFrameElement) || existing.src !== target.href)) {
        throw new Error(`A different widget already uses #${frameId}.`);
      }
      if (existing && destination && existing.parentElement !== destination) {
        throw new Error("Widget is already mounted in a different location.");
      }
      container = destination;
      if (!existing) {
        ownedFrame = document.createElement("iframe");
        ownedFrame.id = frameId;
        ownedFrame.src = target.href;
        (container || document.body).append(ownedFrame);
      }
      mountedFrame = (existing as HTMLIFrameElement | null) || ownedFrame;
      connect();
    },
    async init(context: WidgetInit | DemoWidgetInit) { return connect().init(context); },
    async updateSettings(settings: Partial<WidgetSettings>) { return connect().updateSettings(settings); },
    async getSettings() { return connect().getSettings(); },
    dispose() {
      client?.dispose();
      cleanup?.();
      ownedFrame?.remove();
      ownedFrame = undefined;
      client = undefined;
      cleanup = undefined;
      mountedFrame = undefined;
      container = undefined;
    },
  };
}

declare global {
  interface Window {
    zaq: { widget: ReturnType<typeof createEmbed> };
  }
}

window.zaq = window.zaq || {} as Window["zaq"];
window.zaq.widget = window.zaq.widget || createEmbed();

// A bare embed.js include retains the manual iframe API.
const script = document.currentScript;
if (script instanceof HTMLScriptElement && script.hasAttribute("data-widget-id")) {
  const widgetId = script.dataset.widgetId || "";
  if (widgetId.length > 200 || !/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(widgetId)) {
    throw new Error("Invalid widget ID.");
  }
  const url = new URL(`/widget/${widgetId}`, script.src).href;
  const selector = script.getAttribute("iframe-location-id") ?? undefined;
  const mount = () => window.zaq.widget.mount(url, selector);
  if (document.body && (selector === undefined || document.readyState !== "loading")) mount();
  else document.addEventListener("DOMContentLoaded", mount, { once: true });
}
