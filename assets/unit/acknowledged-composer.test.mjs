import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { AssistantRuntimeProvider, useExternalStoreRuntime } from "@assistant-ui/react";
import { transformWithEsbuild } from "vite";

const source = await readFile(new URL("../react-components/acknowledged-composer.tsx", import.meta.url), "utf8");
const { code } = await transformWithEsbuild(source, "acknowledged-composer.tsx", { jsx: "automatic" });
const compiled = ["react/jsx-runtime", "@assistant-ui/react"].reduce((source, name) => source.replaceAll(JSON.stringify(name), JSON.stringify(import.meta.resolve(name))), code);
const { AcknowledgedComposer } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`);

function Harness(props) {
  const runtime = useExternalStoreRuntime({ messages: [], isRunning: false, onNew: async () => {} });
  runtime.thread.composer.setText("Typed draft");
  return createElement(AssistantRuntimeProvider, { runtime }, createElement(AcknowledgedComposer, {
    ready: true, busy: false, sending: false, draftLocked: false, onSend: () => {}, placeholder: "Message", maxLength: 2000,
    labels: { input: "Message", send: "Envoyer", sending: "Envoi…", working: "Working…", sendMessage: "Send message" }, ...props,
  }));
}

test("pending acknowledgement retains the visible draft and locks input/send with localized Sending", () => {
  const html = renderToStaticMarkup(createElement(Harness, { busy: true, sending: true, draftLocked: true }));
  assert.match(html, /<textarea[^>]*disabled/);
  assert.match(html, />Typed draft<\/textarea>/);
  assert.match(html, /<button[^>]*disabled/);
  assert.match(html, />Envoi…<\/button>/);
  assert.doesNotMatch(html, /data-role="assistant"|data-role="user"/);
});

test("idle and definitive rejection allow editing the retained draft; legacy busy label stays intact", () => {
  const idle = renderToStaticMarkup(createElement(Harness, {}));
  assert.doesNotMatch(idle, /disabled/);
  assert.match(idle, />Envoyer<\/button>/);
  const legacy = renderToStaticMarkup(createElement(Harness, { busy: true }));
  assert.match(legacy, />Working…<\/button>/);
});
