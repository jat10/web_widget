export type WidgetSettings = { theme: "auto" | "light" | "dark"; language: "en" | "fr" | "ar" };
export type WidgetInit = { user_id: string; prompt_context?: string | null; conversation_id?: string | null; settings?: Partial<WidgetSettings> };

/** Create before loading the iframe. Each client is scoped to one iframe and exact origin. */
export function createWidgetClient(iframe: HTMLIFrameElement, url: string) {
  const widgetUrl = new URL(url, window.location.href);
  if (!["https:", "http:"].includes(widgetUrl.protocol)) throw new Error("Widget URL must use HTTP(S).");
  const origin = widgetUrl.origin;
  let disposed = false;
  let ready = false;
  let bootstrap: WidgetInit | undefined;
  let settings: WidgetSettings | undefined;
  const pending = new Map<string, { resolve: (value: WidgetSettings) => void; reject: (error: Error) => void; timer: number }>();
  const waiting = new Set<() => void>();

  const request = (type: string, payload: object): Promise<WidgetSettings> => new Promise((resolve, reject) => {
    if (disposed) return reject(new Error("Widget client is disposed."));
    const request_id = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join("-");
    const send = () => iframe.contentWindow?.postMessage({ type, request_id, ...payload }, origin);
    const timer = window.setTimeout(() => {
      waiting.delete(send); pending.delete(request_id); reject(new Error("Widget request timed out."));
    }, 20000);
    pending.set(request_id, { resolve, reject, timer });
    if (ready) send(); else waiting.add(send);
  });

  const onMessage = (event: MessageEvent) => {
    if (event.source !== iframe.contentWindow || event.origin !== origin) return;
    const data = event.data;
    if (data?.type === "zaq.widget.ready") {
      ready = true;
      for (const send of waiting) send();
      waiting.clear();
      if (bootstrap) void request("zaq.widget.init", { ...bootstrap, settings: settings || bootstrap.settings }).catch(() => {});
    } else if (data?.type === "zaq.widget.disconnected") {
      ready = false;
    } else if (data?.type === "zaq.widget.result") {
      const entry = pending.get(data.request_id);
      if (!entry) return;
      window.clearTimeout(entry.timer);
      pending.delete(data.request_id);
      if (data.ok) { settings = data.settings; entry.resolve({ ...data.settings }); }
      else entry.reject(new Error(data.error || "Widget request rejected."));
    }
  };
  window.addEventListener("message", onMessage);
  iframe.src = widgetUrl.href;

  return {
    async init(context: WidgetInit) {
      const result = await request("zaq.widget.init", context);
      bootstrap = { ...context };
      return result;
    },
    updateSettings(patch: Partial<WidgetSettings>) { return request("zaq.widget.settings.update", { settings: patch }); },
    getSettings() { return request("zaq.widget.settings.get", {}); },
    dispose() {
      disposed = true;
      window.removeEventListener("message", onMessage);
      for (const entry of pending.values()) { window.clearTimeout(entry.timer); entry.reject(new Error("Widget client is disposed.")); }
      pending.clear(); waiting.clear();
    },
  };
}
