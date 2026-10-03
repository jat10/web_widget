import { useEffect, useId, useRef, useState } from "react";
import { useLiveReact } from "live_react";
import {
  AssistantRuntimeProvider,
  ComposerPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
  useAuiState,
  useExternalStoreRuntime,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import "../css/widget.css";

type Mode = "launcher" | "conversation";
type Step = {
  id: string;
  kind: "reasoning" | "tool_call" | "tool_result" | "status";
  label: string;
  content?: string | null;
  state: "started" | "updated" | "completed" | "failed";
};
type Message = { timestamp?: string; dateSeparator?: string; id: string; role: "user" | "assistant"; content: string; steps?: Step[]; status?: "running" | "complete" | "failed"; error?: string | null };
type Config = {
  title: string;
  multiple_conversations?: boolean;
  placeholder: string;
  follow_up_placeholder: string;
  max_length: number;
};
type ConversationSummary = { id: string; title: string };
type Props = { canReopen?: boolean; conversations?: ConversationSummary[]; conversationId?: string | null; mode: Mode; messages: Message[]; isRunning: boolean; isTyping: boolean; responseError?: string | null; config: Config };

const convertMessage = (message: Message): ThreadMessageLike => ({
  id: message.id,
  role: message.role,
  content: message.content,
  metadata: { custom: { steps: message.steps, error: message.error, hasContent: message.content.length > 0, timestamp: message.timestamp, dateSeparator: message.dateSeparator } },
  ...(message.role === "assistant" && {
    status: message.status === "running"
      ? { type: "running" as const }
      : message.status === "failed"
        ? { type: "incomplete" as const, reason: "error" as const, error: message.error || "Unable to complete response" }
        : { type: "complete" as const, reason: "stop" as const },
  }),
});

const calendarDay = (date: Date) => `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
const messageDay = (timestamp?: string) => timestamp ? calendarDay(new Date(timestamp)) : undefined;
function dateLabel(timestamp: string) {
  const date = new Date(timestamp);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(today.getDate() - 1);
  if (calendarDay(date) === calendarDay(today)) return "Today";
  if (calendarDay(date) === calendarDay(yesterday)) return "Yesterday";
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function WebWidget({ mode, messages, isRunning, isTyping, responseError, config, conversations = [], conversationId = null, canReopen = false }: Props) {
  const { pushEvent } = useLiveReact();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const root = useRef<HTMLDivElement>(null);
  const previousMode = useRef(mode);
  const previousConversation = useRef(conversationId);
  const [today, setToday] = useState(() => calendarDay(new Date()));
  useEffect(() => {
    const timer = window.setInterval(() => setToday(calendarDay(new Date())), 60000);
    return () => window.clearInterval(timer);
  }, []);
  const datedMessages = messages.map((message, index) => ({
    ...message,
    dateSeparator: message.timestamp && (index === 0 || messageDay(message.timestamp) !== messageDay(messages[index - 1]?.timestamp))
      ? dateLabel(message.timestamp) : undefined,
  }));

  // LiveView is the source of truth. This runtime only adapts its props for assistant-ui.
  const runtime = useExternalStoreRuntime({
    messages: datedMessages,
    convertMessage,
    isRunning,
    isSendDisabled: submitting || isRunning,
    onNew: async (message) => {
      const text = message.content
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join("\n")
        .trim();
      if (!text) return;
      setSubmitting(true);
      setError(null);
      try {
        await new Promise<void>((resolve, reject) => {
          const timeout = window.setTimeout(() => reject(new Error("Connection interrupted. Please try again.")), 10000);
          try {
            pushEvent("widget.submit", { text }, (reply) => {
              window.clearTimeout(timeout);
              if (reply.ok) resolve();
              else reject(new Error(reply.error));
            });
          } catch (cause) {
            window.clearTimeout(timeout);
            reject(cause);
          }
        });
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : "Unable to send. Please try again.");
        runtime.thread.composer.setText(text);
      } finally {
        setSubmitting(false);
      }
    },
  });

  useEffect(() => {
    if (window.parent === window || !root.current) return;
    const notify = () => window.parent.postMessage({
      type: "zaq.widget.resize",
      mode,
      // The only cross-window data is layout intent, never messages or credentials.
      height: mode === "launcher" ? Math.ceil(root.current!.getBoundingClientRect().height) + 32 : "100%",
    }, "*");
    const observer = new ResizeObserver(notify);
    observer.observe(root.current);
    notify();
    return () => observer.disconnect();
  }, [mode]);

  useEffect(() => {
    if (previousMode.current !== mode) {
      root.current?.querySelector<HTMLElement>(mode === "launcher" ? "[data-widget-reopen]" : ".zaq-composer-input")?.focus();
      previousMode.current = mode;
    }
  }, [mode]);

  useEffect(() => {
    if (previousConversation.current !== conversationId) {
      runtime.thread.composer.setText("");
      setError(null);
      previousConversation.current = conversationId;
    }
  }, [conversationId, runtime]);

  const changeConversation = (event: string, params: { id?: string } = {}) => {
    pushEvent(event, params, reply => {
      if (!reply.ok) setError(reply.error || "Unable to change conversations.");
      else setError(null);
    });
  };

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root ref={root} className="zaq-widget" data-mode={mode} data-multiple-conversations={!!config.multiple_conversations} data-calendar-day={today} aria-label={config.title}>
        {mode === "conversation" && config.multiple_conversations && <ConversationSidebar conversations={conversations} selectedId={conversationId} disabled={submitting || isRunning} onSelect={id => changeConversation("widget.conversation.select", { id })} onNew={() => changeConversation("widget.conversation.new")} />}
        <div className="zaq-chat-main" key="chat-main">
        {mode === "conversation" && <Conversation title={config.title} isTyping={isTyping} onClose={() => pushEvent("widget.close", {})} empty={messages.length === 0} />}
        {mode === "launcher" && canReopen && <button type="button" className="zaq-reopen" data-widget-reopen onClick={() => pushEvent("widget.open", {})}>Open conversation<span aria-hidden="true">↗</span></button>}
        <FloatingComposer key="composer" mode={mode} config={config} busy={submitting || isRunning} error={error || responseError || null} />
        </div>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

function ConversationSidebar({ conversations, selectedId, disabled, onSelect, onNew }: { conversations: ConversationSummary[]; selectedId: string | null; disabled: boolean; onSelect: (id: string) => void; onNew: () => void }) {
  return <aside className="zaq-conversations" aria-label="Conversations">
    <button className="zaq-new-chat" type="button" disabled={disabled} onClick={onNew}><span aria-hidden="true">＋</span>New chat</button>
    <h2>Your conversations</h2>
    <nav aria-label="Conversation history">
      {conversations.map(conversation => <button key={conversation.id} type="button" className="zaq-conversation-item" aria-current={conversation.id === selectedId ? "page" : undefined} disabled={disabled} onClick={() => onSelect(conversation.id)}>{conversation.title}</button>)}
    </nav>
    {conversations.length === 0 && <p>No conversations yet.</p>}
  </aside>;
}

function FloatingComposer({ mode, config, busy, error }: { mode: Mode; config: Config; busy: boolean; error: string | null }) {
  return (
    <footer className="zaq-widget-footer">
      {error && <p className="zaq-widget-error" role="alert">{error}</p>}
      <ComposerPrimitive.Root className="zaq-composer">
        <ComposerPrimitive.Input
          aria-label="Message"
          placeholder={mode === "launcher" ? config.placeholder : config.follow_up_placeholder}
          maxLength={config.max_length}
          className="zaq-composer-input"
        />
        <ComposerPrimitive.Send className="zaq-composer-send" disabled={busy} aria-label="Send message">
          {busy ? "Working…" : "Send"}
        </ComposerPrimitive.Send>
      </ComposerPrimitive.Root>
    </footer>
  );
}

function Conversation({ title, isTyping, onClose, empty }: { title: string; isTyping: boolean; onClose: () => void; empty: boolean }) {
  return (
    <>
      <header className="zaq-widget-header">
        <div className="zaq-header-identity"><span className="zaq-assistant-mark" aria-hidden="true"><ActivityIcon kind="assistant" /></span><div><h1>{title}</h1><p>Here to help you find your next step</p></div></div>
        <div className="zaq-header-actions">
          {isTyping && <span className="zaq-header-status" role="status"><span className="zaq-live-dot" />Assistant is working…</span>}
          <button type="button" className="zaq-close" aria-label="Close chat" title="Close chat" onClick={onClose}><ActivityIcon kind="close" /></button>
        </div>
      </header>
      <ThreadPrimitive.Viewport className="zaq-thread" aria-label="Conversation">
        <div className="zaq-thread-content">
          {empty && <div className="zaq-empty-chat"><h2>How can I help?</h2><p>Start a new conversation or choose one from your history.</p></div>}
          <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
          <ThreadPrimitive.ScrollToBottom className="zaq-scroll-bottom">Latest messages</ThreadPrimitive.ScrollToBottom>
        </div>
      </ThreadPrimitive.Viewport>
    </>
  );
}

function UserMessage() {
  return <><MessageDate /><MessagePrimitive.Root className="zaq-message zaq-message-user" data-role="user"><span className="zaq-user-content"><MessagePrimitive.Parts /></span><MessageTime /></MessagePrimitive.Root></>;
}

function AssistantMessage() {
  const steps = useAuiState((s) => s.message.metadata.custom.steps) as Step[] | undefined;
  const error = useAuiState((s) => s.message.metadata.custom.error) as string | null | undefined;
  const running = useAuiState((s) => s.message.status?.type === "running");
  const hasContent = useAuiState((s) => s.message.metadata.custom.hasContent) as boolean;
  const activeTools = steps?.some(step => step.state === "started" || step.state === "updated");
  return (
    <><MessageDate />
    <MessagePrimitive.Root className="zaq-message zaq-message-assistant" data-role="assistant" data-running={running}>
      <div className="zaq-answer-heading"><span className="zaq-assistant-mark zaq-assistant-mark-small" aria-hidden="true"><ActivityIcon kind="assistant" /></span><span>Assistant</span></div>
      {!!steps?.length && <ResponseActivity steps={steps} running={running} failed={!!error} />}
      <div className="zaq-answer-content" data-streaming={running && hasContent}>
        <MessagePrimitive.Parts />
      </div>
      <MessageTime />
      {running && <WorkingIndicator label={hasContent ? "Writing response" : activeTools ? "Working with tools" : "Preparing your answer"} />}
      {error && <div className="zaq-response-error" role="alert"><ActivityIcon kind="failed" /><div><strong>Couldn't finish this response</strong><p>{error}</p><span>You can send another message below.</span></div></div>}
    </MessagePrimitive.Root></>
  );
}

function MessageDate() {
  const label = useAuiState(s => s.message.metadata.custom.dateSeparator) as string | undefined;
  return label ? <div className="zaq-date-separator" role="separator" aria-label={label}><span>{label}</span></div> : null;
}

function MessageTime() {
  const timestamp = useAuiState(s => s.message.metadata.custom.timestamp) as string | undefined;
  if (!timestamp) return null;
  const date = new Date(timestamp);
  return <time className="zaq-message-time" dateTime={timestamp} title={date.toLocaleString()}>{date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time>;
}

function WorkingIndicator({ label }: { label: string }) {
  return <div className="zaq-working" role="status"><span className="zaq-working-dots" aria-hidden="true"><i /><i /><i /></span><span>{label}</span></div>;
}

function ResponseActivity({ steps, running, failed }: { steps: Step[]; running: boolean; failed: boolean }) {
  const [expanded, setExpanded] = useState<boolean | null>(null);
  const contentId = useId();
  const toggle = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const wasRunning = useRef(running);
  const failedCount = steps.filter(step => step.state === "failed").length;
  const completedCount = steps.filter(step => step.state === "completed").length;
  const hasFailure = failed || failedCount > 0;
  const open = expanded ?? (running || hasFailure);

  useEffect(() => {
    if (wasRunning.current && !running) {
      // Keep keyboard focus reachable when completed activity folds away.
      if (!hasFailure && panel.current?.contains(document.activeElement)) toggle.current?.focus();
      setExpanded(null);
    }
    wasRunning.current = running;
  }, [running, hasFailure]);

  const title = hasFailure ? "Activity needs attention" : running ? "Working on your request" : "View response activity";
  const detail = hasFailure ? `${failedCount} failed · ${completedCount} completed` : running ? `${completedCount} of ${steps.length} completed` : `${steps.length} ${steps.length === 1 ? "step" : "steps"} completed`;

  return (
    <section className="zaq-activity" data-status={hasFailure ? "failed" : running ? "running" : "complete"} aria-label="Response activity">
      <button ref={toggle} type="button" className="zaq-activity-toggle" aria-expanded={open} aria-controls={contentId} onClick={() => setExpanded(!open)}>
        <span className="zaq-activity-symbol"><ActivityIcon kind={hasFailure ? "failed" : running ? "running" : "complete"} /></span>
        <span className="zaq-activity-heading"><strong>{title}</strong><span>{detail}</span></span>
        <span className="zaq-chevron" data-open={open}><ActivityIcon kind="chevron" /></span>
      </button>
      <div ref={panel} id={contentId} className="zaq-activity-steps" hidden={!open}>
        {steps.map(step => <ResponseStep key={step.id} step={step} />)}
      </div>
    </section>
  );
}

function ResponseStep({ step }: { step: Step }) {
  const running = step.state === "started" || step.state === "updated";
  const status = running ? "running" : step.state === "completed" ? "complete" : "failed";
  const kind = { tool_call: "Tool call", tool_result: "Tool result", reasoning: "Reasoning", status: "Activity" }[step.kind];
  return (
    <details className="zaq-response-step" data-kind={step.kind} data-status={status} data-step-id={step.id} open={step.state === "failed" ? true : undefined}>
      <summary>
        <span className="zaq-tool-icon"><ActivityIcon kind={status === "running" ? "running" : status === "failed" ? "failed" : "tool"} /></span>
        <span className="zaq-tool-heading"><span className="zaq-tool-kind">{kind}</span><strong>{step.label}</strong></span>
        <span className="zaq-step-state">{running ? "Running" : step.state === "completed" ? "Done" : "Failed"}</span>
        <span className="zaq-chevron"><ActivityIcon kind="chevron" /></span>
      </summary>
      <div className="zaq-tool-output"><span className="zaq-output-label">{running ? "Progress" : step.state === "failed" ? "Error details" : "Result"}</span><p>{step.content || (running ? "Waiting for the tool to return a result…" : step.state === "failed" ? "This step could not be completed." : "This step finished without additional output.")}</p></div>
    </details>
  );
}

function ActivityIcon({ kind }: { kind: "assistant" | "tool" | "running" | "complete" | "failed" | "chevron" | "close" }) {
  if (kind === "running") return <span className="zaq-spinner" aria-hidden="true" />;
  const paths = {
    assistant: "M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z",
    tool: "m8 7-5 5 5 5m8-10 5 5-5 5m-3-14-2 18",
    complete: "m5 12 4 4L19 6",
    failed: "M12 8v5m0 3v.01M10 3h4l7 16H3L10 3Z",
    chevron: "m8 5 7 7-7 7",
    close: "m6 6 12 12M18 6 6 18",
  };
  return <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d={paths[kind]} /></svg>;
}
