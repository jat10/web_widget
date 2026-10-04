import { createWidgetClient, type WidgetInit, type WidgetSettings } from "./widget-client";

function createEmbed() {
  let client: ReturnType<typeof createWidgetClient> | undefined;
  let cleanup: (() => void) | undefined;

  function connect() {
    if (client) return client;
    const iframe = document.getElementById("zaq-widget");
    if (!(iframe instanceof HTMLIFrameElement) || !iframe.getAttribute("src")) {
      throw new Error('Add an iframe with id="zaq-widget" and a widget src before calling zaq.widget.init().');
    }
    const origin = new URL(iframe.src).origin;
    const originalStyle = iframe.getAttribute("style");
    const originalTitle = iframe.getAttribute("title");
    const originalMode = iframe.getAttribute("data-mode");
    const originalOverflow = document.documentElement.style.overflow;
    const defaults = {
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
      document.documentElement.style.overflow = originalOverflow;
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
    async init(context: WidgetInit) { return connect().init(context); },
    async updateSettings(settings: Partial<WidgetSettings>) { return connect().updateSettings(settings); },
    async getSettings() { return connect().getSettings(); },
    dispose() {
      client?.dispose();
      cleanup?.();
      client = undefined;
      cleanup = undefined;
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
