export type WidgetSettings = { theme: "auto" | "light" | "dark"; language: "en" | "fr" | "ar" };
export type WidgetInit = { identity_token: string };
export type WidgetContextUpdate = { conversation_id?: string | null; prompt_context?: string | null };
/** Standalone mock fixtures only; rejected by integrated ZAQ widgets. */
export type DemoWidgetInit = { user_id: string; prompt_context?: string | null; conversation_id?: string | null };
export type TokenProvider = (signal: AbortSignal) => Promise<string>;

type Result = {
  ok: boolean; error?: string; reason?: string; settings?: WidgetSettings;
  expires_at?: number; refresh_at?: number; server_time?: number; credential_id?: string;
  available?: boolean;
};
type Pending = { type: string; resolve: (value: Result) => void; reject: (error: Error) => void; timer: number };

/** Each client is scoped to one iframe and exact origin, including already loaded frames. */
export function createWidgetClient(
  iframe: HTMLIFrameElement, url: string,
  options: { tokenProvider?: TokenProvider; initialToken?: string } = {},
) {
  const widgetUrl = new URL(url, window.location.href);
  if (!["https:", "http:"].includes(widgetUrl.protocol)) throw new Error("Widget URL must use HTTP(S).");
  const origin = widgetUrl.origin;
  let disposed = false, bootstrapReady = false, publicReady = false, terminal = false;
  let demoBootstrap: DemoWidgetInit | undefined;
  let parentContext: WidgetContextUpdate | undefined;
  let settings: WidgetSettings | undefined;
  let provider = options.tokenProvider;
  let acceptedToken: string | undefined;
  let pendingToken = options.initialToken;
  let expiryDeadline = 0, refreshDeadline = 0, retryCount = 0;
  let renewalTimer: number | undefined, providerAbort: AbortController | undefined;
  let renewal: Promise<Result> | undefined;
  let loadedOnce = false;
  let waitingForStore = false;
  const pending = new Map<string, Pending>();
  const waiting = new Set<() => void>();

  const tokenId = (token: string | undefined): string | undefined => {
    try {
      if (!token) return undefined;
      const payload = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
      const jti = JSON.parse(atob(payload)).jti;
      return typeof jti === "string" ? jti : undefined;
    } catch { return undefined; }
  };
  const request = (type: string, payload: object): Promise<Result> => new Promise((resolve, reject) => {
    if (disposed) return reject(new Error("Widget client is disposed."));
    const request_id = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join("-");
    const send = () => { if (!disposed) iframe.contentWindow?.postMessage({ type, request_id, ...payload }, origin); };
    const timeout = window.setTimeout(() => {
      waiting.delete(send); pending.delete(request_id); reject(new Error("Widget request timed out."));
    }, 20_000);
    pending.set(request_id, { type, resolve, reject, timer: timeout });
    if (bootstrapReady) send(); else waiting.add(send);
  });
  const clearTimer = () => {
    if (renewalTimer !== undefined) window.clearTimeout(renewalTimer);
    renewalTimer = undefined;
  };
  const schedule = () => {
    clearTimer();
    if (disposed || terminal || !provider || !expiryDeadline) return;
    const remaining = expiryDeadline - Date.now();
    if (remaining <= 0) return;
    const delay = Math.max(1_000, Math.min(refreshDeadline - Date.now(), remaining, 2_147_483_647));
    renewalTimer = window.setTimeout(() => { void refresh().catch(() => {}); }, delay);
  };
  const accept = (data: Result) => {
    if (!Number.isFinite(data.expires_at) || !Number.isFinite(data.refresh_at) ||
        !Number.isFinite(data.server_time) || typeof data.credential_id !== "string") return;
    const candidate = pendingToken || acceptedToken;
    if (tokenId(candidate) !== data.credential_id) return;
    acceptedToken = candidate;
    pendingToken = undefined;
    expiryDeadline = Date.now() + (data.expires_at! - data.server_time!) * 1_000;
    refreshDeadline = Date.now() + (data.refresh_at! - data.server_time!) * 1_000;
    retryCount = 0;
    schedule();
    iframe.dispatchEvent(new CustomEvent("zaq:authenticated", { detail: data }));
  };
  const acquire = async () => {
    if (!provider) throw new Error("No token provider configured.");
    providerAbort?.abort();
    providerAbort = new AbortController();
    const token = await provider(providerAbort.signal);
    if (disposed) throw new Error("Widget client is disposed.");
    if (typeof token !== "string" || !token.trim() || !tokenId(token) ||
        tokenId(token) === tokenId(acceptedToken)) {
      throw new Error("Token provider did not return a fresh identity_token.");
    }
    return token;
  };
  const retry = () => {
    if (disposed || terminal || !provider || waitingForStore) return;
    clearTimer();
    if (expiryDeadline && Date.now() >= expiryDeadline) {
      iframe.dispatchEvent(new CustomEvent("zaq:authentication-required", { detail: { reason: "expired" } }));
      return;
    }
    const delay = Math.min(30_000, 1_000 * 2 ** Math.min(retryCount++, 5));
    renewalTimer = window.setTimeout(() => { void refresh(true).catch(() => {}); }, delay);
  };
  const refresh = (force = false): Promise<Result> => {
    if (renewal) return renewal;
    if (disposed || terminal) return Promise.reject(new Error("Widget connection is closed."));
    if (!force && refreshDeadline && Date.now() < refreshDeadline) {
      schedule();
      return Promise.resolve({ ok: true });
    }
    renewal = (async () => {
      const token = await acquire();
      pendingToken = token;
      const result = await request("zaq.widget.connect", { identity_token: token });
      if (!result.ok) throw new Error(result.error || result.reason || "Authentication rejected.");
      accept(result);
      return result;
    })().catch(error => {
      pendingToken = undefined;
      retry();
      throw error;
    }).finally(() => { renewal = undefined; });
    return renewal;
  };
  const pollStore = () => {
    if (disposed || terminal || !provider) return;
    waitingForStore = true;
    clearTimer();
    renewalTimer = window.setTimeout(async () => {
      try {
        if (!bootstrapReady) { pollStore(); return; }
        const status = await request("zaq.widget.auth.status", {});
        if (!status.available) { pollStore(); return; }
        waitingForStore = false;
        void refresh(true).catch(() => {});
      } catch { pollStore(); }
    }, 2_000);
  };
  const connect = async (context?: WidgetInit): Promise<Result> => {
    if (!context) return refresh(true);
    if (Object.keys(context).some(key => key !== "identity_token") || !tokenId(context.identity_token)) {
      throw new Error("Invalid connect fields.");
    }
    pendingToken = context.identity_token;
    const result = await request("zaq.widget.connect", context);
    accept(result);
    return result;
  };

  const onMessage = (event: MessageEvent) => {
    if (event.source !== iframe.contentWindow || event.origin !== origin) return;
    const data = event.data;
    if (data?.type === "zaq.widget.bootstrap.ready") {
      const firstReady = !bootstrapReady;
      bootstrapReady = true;
      for (const send of waiting) send();
      waiting.clear();
      if (firstReady && (demoBootstrap || settings)) {
        void (async () => {
          if (demoBootstrap) await request("zaq.widget.init", demoBootstrap);
          if (settings) await request("zaq.widget.settings.update", { settings });
        })().catch(() => {});
      }
      if (waitingForStore) pollStore(); else schedule();
    } else if (data?.type === "zaq.widget.ready") {
      const firstReady = !publicReady;
      publicReady = true;
      iframe.dispatchEvent(new CustomEvent("zaq:ready"));
      if (firstReady && parentContext) void request("zaq.widget.context.update", parentContext).catch(() => {});
    } else if (data?.type === "zaq.widget.disconnected") {
      bootstrapReady = false; publicReady = false;
      iframe.dispatchEvent(new CustomEvent("zaq:disconnected", { detail: { reason: data.reason || "network" } }));
    } else if (data?.type === "zaq.widget.authenticated") {
      accept(data);
    } else if (data?.type === "zaq.widget.conversation" && typeof data.conversation_id === "string") {
      if (demoBootstrap) demoBootstrap.conversation_id = data.conversation_id;
      iframe.dispatchEvent(new CustomEvent("zaq:conversation", { detail: { conversation_id: data.conversation_id } }));
    } else if (data?.type === "zaq.widget.authentication.required") {
      const reason = typeof data.reason === "string" ? data.reason : "expired";
      iframe.dispatchEvent(new CustomEvent("zaq:authentication-required", { detail: { reason } }));
      if (reason === "backend_revoked") {
        terminal = true; clearTimer();
      } else if (reason === "store_unavailable") {
        pollStore();
      } else if (provider && reason !== "network") {
        void refresh(true).catch(() => {});
      }
    } else if (data?.type === "zaq.widget.result") {
      const entry = pending.get(data.request_id);
      if (!entry) return;
      window.clearTimeout(entry.timer); pending.delete(data.request_id);
      if (data.ok) {
        if (data.settings && ["zaq.widget.settings.get", "zaq.widget.settings.update"].includes(entry.type)) settings = data.settings;
        entry.resolve(data);
      } else {
        if (data.reason === "store_unavailable") pollStore();
        entry.reject(new Error(data.error || data.reason || "Widget request rejected."));
      }
    }
  };
  const probe = () => iframe.contentWindow?.postMessage({ type: "zaq.widget.ready.request" }, origin);
  const onLoad = () => {
    bootstrapReady = false; publicReady = false;
    if (loadedOnce && provider && !waitingForStore) void refresh(true).catch(() => {});
    loadedOnce = true;
    probe();
  };
  const onWake = () => {
    if (disposed || terminal || !provider || !expiryDeadline) return;
    if (waitingForStore) { pollStore(); return; }
    if (Date.now() >= refreshDeadline && bootstrapReady) void refresh(true).catch(() => {});
    else schedule();
  };
  const onVisibility = () => { if (document.visibilityState === "visible") onWake(); };
  window.addEventListener("message", onMessage);
  window.addEventListener("online", onWake);
  document.addEventListener("visibilitychange", onVisibility);
  iframe.addEventListener("load", onLoad);
  if (iframe.src !== widgetUrl.href) iframe.src = widgetUrl.href;
  probe();

  return {
    connect,
    async init(context: WidgetInit | DemoWidgetInit) {
      if ("identity_token" in context) return connect(context);
      const allowed = ["user_id", "conversation_id", "prompt_context"];
      if (Object.keys(context).some(key => !allowed.includes(key))) {
        throw new Error("Unsupported init field. Use signed claims and updateSettings.");
      }
      const result = await request("zaq.widget.init", context);
      demoBootstrap = { ...context };
      return result;
    },
    async updateSettings(patch: Partial<WidgetSettings>) {
      const result = await request("zaq.widget.settings.update", { settings: patch });
      return result.settings!;
    },
    async updateContext(context: WidgetContextUpdate) {
      if (!context || typeof context !== "object" || Array.isArray(context) ||
          Object.keys(context).some(key => !["conversation_id", "prompt_context"].includes(key))) {
        throw new Error("Invalid widget context update.");
      }
      const result = await request("zaq.widget.context.update", context);
      parentContext = { ...context };
      return result;
    },
    async getSettings() {
      const result = await request("zaq.widget.settings.get", {});
      return result.settings!;
    },
    setTokenProvider(next: TokenProvider) { provider = next; schedule(); },
    isReady() { return publicReady; },
    dispose() {
      disposed = true; clearTimer(); providerAbort?.abort();
      window.removeEventListener("message", onMessage);
      window.removeEventListener("online", onWake);
      document.removeEventListener("visibilitychange", onVisibility);
      iframe.removeEventListener("load", onLoad);
      for (const entry of pending.values()) {
        window.clearTimeout(entry.timer);
        entry.reject(new Error("Widget client is disposed."));
      }
      pending.clear(); waiting.clear();
    },
  };
}
