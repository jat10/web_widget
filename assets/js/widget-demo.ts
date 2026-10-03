// Demo host only. The production parent SDK is intentionally out of scope.
const frame = document.querySelector<HTMLIFrameElement>("#zaq-demo-widget");

if (frame) {
  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== frame.contentWindow || event.origin !== window.location.origin) return;
    const data = event.data;
    if (data?.type === "zaq.widget.ready") {
      frame.contentWindow?.postMessage({
        type: "zaq.widget.init",
        user_id: "demo-user",
        prompt_context: `Current page: ${window.location.pathname}`,
        conversation_id: null,
      }, window.location.origin);
      return;
    }
    if (!data || data.type !== "zaq.widget.resize") return;
    if (data.mode !== "launcher" && data.mode !== "conversation") return;

    frame.dataset.mode = data.mode;
    if (data.mode === "launcher" && typeof data.height === "number" && Number.isFinite(data.height)) {
      frame.style.height = `${Math.min(260, Math.max(96, data.height))}px`;
    } else if (data.mode === "conversation") {
      frame.style.height = "100dvh";
      document.documentElement.style.overflow = "hidden";
    }
  });
}
