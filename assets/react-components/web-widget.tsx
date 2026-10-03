import { useEffect, useRef, useState } from "react";
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
  type: "response.step";
  kind: "reasoning" | "tool_call";
  text: string;
  status: "running" | "complete";
};
type Message = { id: string; role: "user" | "assistant"; content: string; step?: Step };
type Config = {
  title: string;
  placeholder: string;
  follow_up_placeholder: string;
  max_length: number;
};
type Props = { mode: Mode; messages: Message[]; isRunning: boolean; config: Config };

const convertMessage = (message: Message): ThreadMessageLike => ({
  id: message.id,
  role: message.role,
  content: message.content,
  metadata: { custom: { step: message.step } },
  ...(message.role === "assistant" && {
    status: message.step?.status === "running"
      ? { type: "running" as const }
      : { type: "complete" as const, reason: "stop" as const },
  }),
});

export function WebWidget({ mode, messages, isRunning, config }: Props) {
  const { pushEvent } = useLiveReact();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const root = useRef<HTMLDivElement>(null);

  // LiveView is the source of truth. This runtime only adapts its props for assistant-ui.
  const runtime = useExternalStoreRuntime({
    messages,
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

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root ref={root} className="zaq-widget" data-mode={mode} aria-label={config.title}>
        {mode === "conversation" && <Conversation title={config.title} />}
        <FloatingComposer key="composer" mode={mode} config={config} busy={submitting || isRunning} error={error} />
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
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

function Conversation({ title }: { title: string }) {
  return (
    <>
      <header className="zaq-widget-header">
        <h1>{title}</h1>
        <span>Prototype · Mock responses</span>
      </header>
      <ThreadPrimitive.Viewport className="zaq-thread" aria-label="Conversation">
        <div className="zaq-thread-content">
          <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
          <ThreadPrimitive.ScrollToBottom className="zaq-scroll-bottom">Latest messages</ThreadPrimitive.ScrollToBottom>
        </div>
      </ThreadPrimitive.Viewport>
    </>
  );
}

function UserMessage() {
  return <MessagePrimitive.Root className="zaq-message zaq-message-user" data-role="user"><MessagePrimitive.Parts /></MessagePrimitive.Root>;
}

function AssistantMessage() {
  const step = useAuiState((s) => s.message.metadata.custom.step) as Step | undefined;
  return (
    <MessagePrimitive.Root className="zaq-message zaq-message-assistant" data-role="assistant">
      {step && <ResponseStep step={step} />}
      <MessagePrimitive.Parts />
    </MessagePrimitive.Root>
  );
}

function ResponseStep({ step }: { step: Step }) {
  return (
    <p className="zaq-response-step" role="status" data-kind={step.kind} data-status={step.status}>
      <span className="zaq-step-indicator" aria-hidden="true" />
      {step.status === "running" ? step.text : "Mock knowledge-base search complete"}
    </p>
  );
}
