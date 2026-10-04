import type { WidgetSettings } from "./widget-client";

if (document.querySelector("#zaq-widget")) {
  const params = new URLSearchParams(window.location.search);
  void window.zaq.widget.init({
    user_id: "demo-user",
    prompt_context: `Current page: ${window.location.pathname}`,
    conversation_id: null,
    settings: {
      theme: (params.get("theme") || "auto") as WidgetSettings["theme"],
      language: (params.get("language") || "en") as WidgetSettings["language"],
    },
  }).catch(error => console.error("Could not initialize demo widget", error));
}
