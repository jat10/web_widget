import { ViewHook } from "phoenix_live_view";

const nonblank = (value: unknown): value is string =>
  typeof value === "string" && value.trim().length > 0;

export class WidgetContext extends ViewHook {
  private accepted = false;
  private contextTimer?: number;

  private reportError(reason: string) {
    console.error(`[WebWidget] ${reason} The chat requires a valid user_id. In the parent page, listen for "zaq.widget.ready", verify event.source === iframe.contentWindow and event.origin === the widget origin, then call iframe.contentWindow.postMessage({ type: "zaq.widget.init", user_id: "user_123", prompt_context: "Current page: /billing", conversation_id: null }, widgetOrigin). prompt_context must be a string or null. Use the exact widget origin; the current widget supports same-origin embedding only.`);
  }

  private receiveContext = (event: MessageEvent) => {
    if (window.parent === window || event.source !== window.parent || event.origin !== window.location.origin) return;
    const data = event.data;
    if (!data || data.type !== "zaq.widget.init") return;
    if (!nonblank(data.user_id)) {
      this.reportError("Missing or invalid user_id in zaq.widget.init.");
      return;
    }

    const conversation_id = data.conversation_id ?? null;
    const prompt_context = data.prompt_context ?? null;
    if (conversation_id !== null && !nonblank(conversation_id)) {
      this.reportError("conversation_id must be a nonblank string or null.");
      return;
    }
    if (prompt_context !== null && typeof prompt_context !== "string") {
      this.reportError("Invalid prompt_context: objects and arrays are not supported.");
      return;
    }

    this.pushEvent("widget.context", { user_id: data.user_id, prompt_context, conversation_id }, (reply) => {
      if (reply.ok) {
        this.accepted = true;
        window.clearTimeout(this.contextTimer);
      } else {
        this.reportError(reply.error || "Widget context was rejected.");
      }
    });
  };

  mounted() {
    window.addEventListener("message", this.receiveContext);
    this.announceReady();
  }

  reconnected() {
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
    if (!this.accepted) {
      this.contextTimer = window.setTimeout(() => {
        this.reportError("No valid user_id received within 5 seconds of zaq.widget.ready; the chat remains hidden. Send valid context to continue.");
      }, 5000);
    }
    window.parent.postMessage({ type: "zaq.widget.ready" }, window.location.origin);
  }
}
