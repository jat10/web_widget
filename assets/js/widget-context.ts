import { ViewHook } from "phoenix_live_view";

type Settings = { theme: "auto" | "light" | "dark"; language: "en" | "fr" | "ar" };
// Module state belongs to this iframe document and survives LiveView remounts.
let sessionSettings: Settings = { theme: "auto", language: "en" };
let initialized = false;
let hasSettings = false;
const nonblank = (value: unknown): value is string => typeof value === "string" && value.trim().length > 0;

export class WidgetContext extends ViewHook {
  private accepted = false;
  private contextTimer?: number;
  private allowedDomains: string[] = [];
  private queue = Promise.resolve();

  private reportError(reason: string) {
    console.error(`[WebWidget] ${reason} The chat requires a valid user_id. In the parent page, listen for "zaq.widget.ready", verify event.source === iframe.contentWindow and event.origin === the widget origin, then call iframe.contentWindow.postMessage({ type: "zaq.widget.init", user_id: "user_123", prompt_context: "Current page: /billing", conversation_id: null }, widgetOrigin). prompt_context must be a string or null. Use the exact widget origin; the parent origin must be listed in the widget’s allowed_domains.`);
  }

  private receiveContext = (event: MessageEvent) => {
    if (window.parent === window || event.source !== window.parent || !this.allowedDomains.includes(event.origin)) return;
    if (!["zaq.widget.init", "zaq.widget.settings.update", "zaq.widget.settings.get"].includes(event.data?.type)) return;
    this.queue = this.queue.then(() => this.receive(event));
  };

  private async receive(event: MessageEvent) {
    const data = event.data;
    try {
      let reply: any;
      if (data.type === "zaq.widget.init") {
        if (!nonblank(data.user_id)) throw new Error("Missing or invalid user_id in zaq.widget.init.");
        const conversation_id = data.conversation_id ?? null;
        const prompt_context = data.prompt_context ?? null;
        if (conversation_id !== null && !nonblank(conversation_id)) throw new Error("conversation_id must be a nonblank string or null.");
        if (prompt_context !== null && typeof prompt_context !== "string") throw new Error("Invalid prompt_context: objects and arrays are not supported.");
        reply = await this.dispatch("widget.context", {
          user_id: data.user_id, conversation_id, prompt_context,
          settings: initialized ? sessionSettings : (data.settings === undefined ? {} : data.settings),
        });
        if (reply.ok) {
          this.accepted = true;
          initialized = true;
          window.clearTimeout(this.contextTimer);
        }
      } else {
        reply = await this.dispatch(data.type === "zaq.widget.settings.get" ? "widget.settings.get" : "widget.settings.update", { settings: data.settings });
      }
      if (!reply.ok) throw new Error(reply.error);
      sessionSettings = reply.settings;
      hasSettings = true;
      await this.applyDocumentSettings();
      this.respond(event, { ok: true, settings: sessionSettings });
    } catch (error) {
      const message = error instanceof Error ? error.message : "Widget request failed.";
      this.respond(event, { ok: false, error: message });
      if (data.type === "zaq.widget.init") this.reportError(message);
    }
  }

  private respond(event: MessageEvent, reply: object) {
    if (nonblank(event.data.request_id)) window.parent.postMessage({ type: "zaq.widget.result", request_id: event.data.request_id, ...reply }, event.origin);
  }

  private dispatch(name: string, params: object): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => reject(new Error("Widget request timed out.")), 10000);
      try {
        this.pushEvent(name, params, reply => { window.clearTimeout(timer); resolve(reply); });
      } catch (error) {
        window.clearTimeout(timer);
        reject(error);
      }
    });
  }

  private async applyDocumentSettings() {
    document.documentElement.lang = sessionSettings.language;
    document.documentElement.dir = sessionSettings.language === "ar" ? "rtl" : "ltr";
    if (document.getElementById("widget-state")?.dataset.contextReceived !== "true") return;
    // React applies LiveView props asynchronously. Acknowledge after its commit.
    await new Promise<void>((resolve, reject) => {
      const matches = () => {
        const root = document.querySelector<HTMLElement>(".zaq-widget");
        return root?.dataset.language === sessionSettings.language && root?.dataset.theme === sessionSettings.theme;
      };
      if (matches()) return resolve();
      const observer = new MutationObserver(() => {
        if (matches()) { window.clearTimeout(timer); observer.disconnect(); resolve(); }
      });
      const timer = window.setTimeout(() => { observer.disconnect(); reject(new Error("Widget render timed out.")); }, 5000);
      observer.observe(document.body, { subtree: true, childList: true, attributes: true });
    });
  }

  mounted() {
    this.allowedDomains = JSON.parse(this.el.dataset.allowedDomains || "[]");
    window.addEventListener("message", this.receiveContext);
    void this.restoreAndAnnounce();
  }

  disconnected() {
    for (const origin of this.allowedDomains) window.parent.postMessage({ type: "zaq.widget.disconnected" }, origin);
  }

  reconnected() {
    void this.restoreAndAnnounce();
  }

  private async restoreAndAnnounce() {
    // Restore preferences before the parent's repeated bootstrap can run.
    if (hasSettings) {
      try { await this.dispatch("widget.settings.update", { settings: sessionSettings }); }
      catch { /* The parent can retry once readiness is announced. */ }
    }
    this.announceReady();
  }

  destroyed() {
    window.clearTimeout(this.contextTimer);
    window.removeEventListener("message", this.receiveContext);
  }

  private announceReady() {
    window.clearTimeout(this.contextTimer);
    if (window.parent === window) {
      this.reportError("No embedding parent found. Open /widget-demo or embed /widget in an iframe.");
      return;
    }
    if (!this.accepted) this.contextTimer = window.setTimeout(() => this.reportError("No valid user_id received within 5 seconds of zaq.widget.ready; the chat remains hidden. Send valid context to continue."), 5000);
    for (const origin of this.allowedDomains) window.parent.postMessage({ type: "zaq.widget.ready" }, origin);
  }
}
