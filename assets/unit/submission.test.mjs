import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { transformWithEsbuild } from "vite";

const source = await readFile(new URL("../js/submission.ts", import.meta.url), "utf8");
const { code } = await transformWithEsbuild(source, "submission.ts");
const { SubmissionController } = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);

let tabId = 0;
function tab(draft) {
  const prefix = ++tabId;
  const calls = [];
  let timer;
  const input = { text: draft };
  const controller = new SubmissionController({
    getDraft: () => input.text,
    setDraft: text => { input.text = text; },
    send: (text, id, reply) => calls.push({ text, id, reply }),
    createId: () => `submission-${prefix}-${calls.length}`,
    unknownMessage: "Unknown outcome",
    setTimer: callback => { timer = callback; return () => { timer = undefined; }; },
  });
  return { controller, input, calls, timeout: () => timer?.() };
}

test("sending retains the exact typed draft and blocks another send until saved acknowledgement", () => {
  const tab1 = tab("  Question  ");
  tab1.controller.submit();
  assert.equal(tab1.input.text, "  Question  ");
  assert.equal(tab1.calls[0].text, "Question");
  assert.equal(tab1.controller.getSnapshot().pending.status, "sending");
  tab1.controller.submit();
  assert.equal(tab1.calls.length, 1);
  tab1.calls[0].reply({ ok: true });
  assert.equal(tab1.input.text, "");
  assert.equal(tab1.controller.getSnapshot().pending, null);
});

test("other-tab acknowledgements never clear a draft or settle its pending request", () => {
  const first = tab("First draft");
  const other = tab("Other draft");
  first.controller.submit();
  other.controller.submit();
  other.controller.acknowledge(first.calls[0].id);
  assert.equal(other.input.text, "Other draft");
  assert.notEqual(other.controller.getSnapshot().pending, null);
  first.controller.acknowledge("another-request");
  assert.equal(first.input.text, "First draft");
  assert.notEqual(first.controller.getSnapshot().pending, null);
});

test("definitive rejection keeps the draft and allows retry", () => {
  const first = tab("Retry me");
  first.controller.submit();
  first.calls[0].reply({ ok: false, error: "Rejected" });
  assert.equal(first.input.text, "Retry me");
  assert.equal(first.controller.getSnapshot().pending, null);
  first.controller.submit();
  assert.equal(first.calls.length, 2);
});

test("timeout, disconnect, and acknowledgement_unavailable hold the draft until matching recovery", () => {
  for (const uncertain of [t => t.timeout(), t => t.controller.disconnected(), t => t.calls[0].reply({ ok: false, outcome: "unknown", error: "Acknowledgement unavailable" })]) {
    const first = tab("Do not duplicate");
    first.controller.submit();
    const id = first.calls[0].id;
    uncertain(first);
    assert.equal(first.input.text, "Do not duplicate");
    assert.equal(first.controller.getSnapshot().pending.status, "unknown");
    first.controller.submit();
    assert.equal(first.calls.length, 1);
    first.controller.acknowledge(id);
    assert.equal(first.input.text, "");
    assert.equal(first.controller.getSnapshot().pending, null);
    first.calls[0].reply({ ok: false, outcome: "unknown", error: "Late callback" });
    assert.equal(first.controller.getSnapshot().error, null);
  }
});

test("matching acknowledgement does not erase a different draft and duplicates are harmless", () => {
  const first = tab("Submitted");
  first.controller.submit();
  first.input.text = "Different draft";
  first.controller.acknowledge(first.calls[0].id);
  first.calls[0].reply({ ok: true });
  assert.equal(first.input.text, "Different draft");
  assert.equal(first.controller.getSnapshot().pending, null);
});

test("disposed submission callbacks cannot clear a replacement view's draft", () => {
  const first = tab("Keep this draft");
  first.controller.submit();
  first.controller.dispose();
  first.calls[0].reply({ ok: true });
  assert.equal(first.input.text, "Keep this draft");
});
