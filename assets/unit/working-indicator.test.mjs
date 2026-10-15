import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { transformWithEsbuild } from "vite";

// Exercise the real presentation component using the existing TSX build tooling.
const source = await readFile(new URL("../react-components/working-indicator.tsx", import.meta.url), "utf8");
const { code } = await transformWithEsbuild(source, "working-indicator.tsx", { jsx: "automatic" });
const compiled = code.replaceAll('"react/jsx-runtime"', JSON.stringify(import.meta.resolve("react/jsx-runtime")));
const { ConversationProgress, WorkingIndicator } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`);

const label = "Préparation de votre réponse";
const render = (isTyping, messages = []) => renderToStaticMarkup(createElement(ConversationProgress, { isTyping, messages, label }));
const history = Object.freeze([
  Object.freeze({ id: "saved-user", role: "user", status: "complete", content: "Question" }),
  Object.freeze({ id: "saved-answer", role: "assistant", status: "complete", content: "Answer" }),
]);

test("active recovery without an assistant create uses the existing localized working indicator", () => {
  for (const messages of [[], history]) {
    const html = render(true, messages);
    assert.match(html, /class="zaq-working" role="status"/);
    assert.match(html, /Préparation de votre réponse/);
    assert.equal((html.match(/class="zaq-working"/g) || []).length, 1);
    assert.doesNotMatch(html, /\bid=|data-role=|data-running=/);
  }
  assert.match(renderToStaticMarkup(createElement(WorkingIndicator, { label })), /zaq-working-dots/);
});

test("real create, full-body edit, or activity takes over without a duplicate indicator", () => {
  for (const message of [
    { id: "live", role: "assistant", status: "running", content: "" },
    { id: "live", role: "assistant", status: "running", content: "Full snapshot" },
    { id: "live", role: "assistant", status: "running", content: "", steps: [{ id: "activity", state: "updated" }] },
  ]) {
    assert.equal(render(true, [...history, message]), "");
  }
});

test("terminal after missed create, failure, and inactive typing remove the fallback", () => {
  assert.notEqual(render(true, history), "");
  assert.equal(render(false, [...history, { id: "old-answer", role: "assistant", status: "complete", content: "Original answer" }]), "");
  assert.equal(render(false, [...history, { id: "failed-answer", role: "assistant", status: "failed", error: "Public failure" }]), "");
  assert.equal(render(false, history), "");
});

test("idle, unknown, and local no-answer submission do not infer processing", () => {
  for (const messages of [[], history, [{ id: "local-user", role: "user", content: "Steering input" }]]) {
    assert.equal(render(false, messages), "");
  }
});

test("completed history does not suppress known active processing or mutate messages", () => {
  const before = JSON.stringify(history);
  assert.notEqual(render(true, history), "");
  assert.notEqual(render(true, [{ role: "user", status: "running" }]), "");
  assert.equal(JSON.stringify(history), before);
});
