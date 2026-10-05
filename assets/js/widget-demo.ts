import type { WidgetSettings } from "./widget-client";

const installation = document.querySelector(".zaq-demo")
  ? document.querySelector<HTMLScriptElement>("script[data-widget-id]")
  : null;

if (installation) {
  let initialized = false;
  const params = new URLSearchParams(window.location.search);
  const initialize = () => {
    if (initialized || !window.zaq?.widget || !document.querySelector("#zaq-widget")) return;
    initialized = true;
    installation.removeEventListener("load", initialize);
    void window.zaq.widget.init({
      user_id: "demo-user",
      prompt_context: `Current page: ${window.location.pathname}`,
      conversation_id: null,
    }).then(() => window.zaq.widget.updateSettings({
        theme: (params.get("theme") || "light") as WidgetSettings["theme"],
        language: (params.get("language") || "en") as WidgetSettings["language"],
    })).catch(error => console.error("Could not initialize demo widget", error));
  };
  installation.addEventListener("load", initialize, { once: true });
  initialize();
}
