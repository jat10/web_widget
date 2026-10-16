type Pending = { id: string; draft: string; text: string; status: "sending" | "unknown" };
type Snapshot = { pending: Pending | null; error: string | null };
type Reply = { ok: boolean; error?: string; outcome?: string | null };
type Options = {
  getDraft: () => string;
  setDraft: (text: string) => void;
  send: (text: string, id: string, reply: (value: Reply) => void) => void;
  unknownMessage: string;
  timeoutMessage?: string;
  createId?: () => string;
  setTimer?: (callback: () => void, milliseconds: number) => () => void;
};

export class SubmissionController {
  private state: Snapshot = { pending: null, error: null };
  private listeners = new Set<() => void>();
  private cancelTimer?: () => void;
  constructor(private options: Options) {}

  getSnapshot = () => this.state;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };

  submit() {
    if (this.state.pending) return;
    const draft = this.options.getDraft();
    const text = draft.trim();
    if (!text) return;
    const id = this.options.createId?.() ?? crypto.randomUUID();
    this.update({ pending: { id, draft, text, status: "sending" }, error: null });
    const setTimer = this.options.setTimer ?? ((callback, milliseconds) => {
      const timer = globalThis.setTimeout(callback, milliseconds);
      return () => globalThis.clearTimeout(timer);
    });
    this.cancelTimer = setTimer(() => this.uncertain(id, this.options.timeoutMessage || this.options.unknownMessage), 300000);
    try {
      this.options.send(text, id, reply => {
        if (this.state.pending?.id !== id) return;
        if (reply.ok) this.acknowledge(id);
        else if (reply.outcome === "unknown") this.uncertain(id, reply.error || this.options.unknownMessage);
        else {
          this.cancelTimer?.();
          this.update({ pending: null, error: reply.error || "Unable to send. Please try again." });
        }
      });
    } catch {
      this.uncertain(id, this.options.unknownMessage);
    }
  }

  acknowledge(id: string) {
    const pending = this.state.pending;
    if (!pending || pending.id !== id) return;
    this.cancelTimer?.();
    if (this.options.getDraft() === pending.draft) this.options.setDraft("");
    this.update({ pending: null, error: null });
  }

  disconnected() {
    if (this.state.pending) this.uncertain(this.state.pending.id, this.options.unknownMessage);
  }

  dispose() { this.cancelTimer?.(); this.state = { pending: null, error: null }; }

  private uncertain(id: string, error: string) {
    const pending = this.state.pending;
    if (!pending || pending.id !== id) return;
    this.cancelTimer?.();
    this.update({ pending: { ...pending, status: "unknown" }, error });
  }

  private update(state: Snapshot) {
    this.state = state;
    this.listeners.forEach(listener => listener());
  }
}
