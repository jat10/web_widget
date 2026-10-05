export type WidgetSettings = { theme: "auto" | "light" | "dark"; language: "en" | "fr" | "ar" };
export type WidgetInit = { identity_token: string };
/** Standalone mock fixtures only; rejected by integrated ZAQ widgets. */
export type DemoWidgetInit = { user_id: string; prompt_context?: string | null; conversation_id?: string | null };


/** Each client is scoped to one iframe and exact origin, including already loaded frames. */
export function createWidgetClient(iframe: HTMLIFrameElement, url: string) {
  const widgetUrl = new URL(url, window.location.href);
  if (!["https:", "http:"].includes(widgetUrl.protocol)) throw new Error("Widget URL must use HTTP(S).");
  const origin = widgetUrl.origin;
  let disposed = false;
  let ready = false;
  let bootstrap: WidgetInit | DemoWidgetInit | undefined;
  let settings: WidgetSettings | undefined;
  const pending = new Map<string, { resolve: (value: WidgetSettings) => void; reject: (error: Error) => void; timer: number; notifyAuth: boolean }>();
  const waiting = new Set<() => void>();

  const request = (type: string, payload: object, notifyAuth = false): Promise<WidgetSettings> => new Promise((resolve, reject) => {
    if (disposed) return reject(new Error("Widget client is disposed."));
    const request_id = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join("-");
    const send = () => iframe.contentWindow?.postMessage({ type, request_id, ...payload }, origin);
    const timer = window.setTimeout(() => {
      waiting.delete(send); pending.delete(request_id); reject(new Error("Widget request timed out."));
    }, 20000);
    pending.set(request_id, { resolve, reject, timer, notifyAuth });
    if (ready) send(); else waiting.add(send);
  });

  const onMessage = (event: MessageEvent) => {
    if (event.source !== iframe.contentWindow || event.origin !== origin) return;
    const data = event.data;
    if (data?.type === "zaq.widget.ready") {
      if (ready) return;
      ready = true;
      for (const send of waiting) send();
      waiting.clear();
      if (bootstrap) {
        const context = bootstrap;
        const preferences = settings;
        void (async () => {
          if (preferences) await request("zaq.widget.settings.update", { settings: preferences });
          await request("zaq.widget.init", context, true);
        })().catch(() => {});
      }
    } else if (data?.type === "zaq.widget.disconnected") {
      ready = false;
    } else if (data?.type === "zaq.widget.conversation" && typeof data.conversation_id === "string") {
      if (bootstrap && "user_id" in bootstrap) bootstrap.conversation_id = data.conversation_id;
      iframe.dispatchEvent(new CustomEvent("zaq:conversation", { detail: { conversation_id: data.conversation_id } }));
    } else if (data?.type === "zaq.widget.authentication.required") {
      iframe.dispatchEvent(new CustomEvent("zaq:authentication-required"));
    } else if (data?.type === "zaq.widget.result") {
      const entry = pending.get(data.request_id);
      if (!entry) return;
      window.clearTimeout(entry.timer);
      pending.delete(data.request_id);
      if (data.ok) { settings = data.settings; entry.resolve({ ...data.settings }); }
      else {
        if (entry.notifyAuth && bootstrap && "identity_token" in bootstrap) iframe.dispatchEvent(new CustomEvent("zaq:authentication-required"));
        entry.reject(new Error(data.error || "Widget request rejected."));
      }
    }
  };
  const probe = () => iframe.contentWindow?.postMessage({ type: "zaq.widget.ready.request" }, origin);
  const onLoad = () => { ready = false; probe(); };
  window.addEventListener("message", onMessage);
  iframe.addEventListener("load", onLoad);
  if (iframe.src !== widgetUrl.href) iframe.src = widgetUrl.href;
  probe();

  return {
    async init(context: WidgetInit | DemoWidgetInit) {
      const allowed = "identity_token" in context ? ["identity_token"] : ["user_id", "conversation_id", "prompt_context"];
      if (Object.keys(context).some(key => !allowed.includes(key))) throw new Error("Unsupported init field. Use signed claims and updateSettings.");
      const result = await request("zaq.widget.init", context);
      bootstrap = { ...context };
      return result;
    },
    updateSettings(patch: Partial<WidgetSettings>) { return request("zaq.widget.settings.update", { settings: patch }); },
    getSettings() { return request("zaq.widget.settings.get", {}); },
    dispose() {
      disposed = true;
      window.removeEventListener("message", onMessage);
      iframe.removeEventListener("load", onLoad);
      for (const entry of pending.values()) { window.clearTimeout(entry.timer); entry.reject(new Error("Widget client is disposed.")); }
      pending.clear(); waiting.clear();
    },
  };
}
