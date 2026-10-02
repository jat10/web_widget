import {
  AssistantRuntimeProvider,
  AuiIf,
  ComposerPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
  useLocalRuntime,
  type ChatModelAdapter,
} from "@assistant-ui/react";

export type AssistantUIProps = {
  title?: string;
  welcomeMessage?: string;
  /** Supply from React when connecting a backend; functions cannot cross LiveReact props. */
  adapter?: ChatModelAdapter;
};

const disconnectedAdapter: ChatModelAdapter = {
  async run() {
    throw new Error("No chat backend is configured.");
  },
};

export function AssistantUI({
  title = "Assistant",
  welcomeMessage = "How can I help you today?",
  adapter,
}: AssistantUIProps) {
  const runtime = useLocalRuntime(adapter ?? disconnectedAdapter);

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root
        aria-label={title}
        className="flex h-[min(40rem,75dvh)] min-h-80 flex-col overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 text-base-content shadow-sm"
      >
        <header className="border-b border-base-content/10 px-6 py-4">
          <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
          {!adapter && (
            <p role="status" className="mt-1 text-sm text-base-content/60">
              Chat is not connected yet.
            </p>
          )}
        </header>

        <ThreadPrimitive.Viewport className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-6 py-6">
          <AuiIf condition={(s) => s.thread.isEmpty}>
            <div className="flex flex-1 items-center justify-center py-12 text-center">
              <p className="text-xl font-medium tracking-tight">{welcomeMessage}</p>
            </div>
          </AuiIf>
          <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
          <ThreadPrimitive.ScrollToBottom className="self-center rounded-full border border-base-content/15 px-4 py-2 text-sm transition hover:bg-base-200 disabled:hidden">
            Latest messages
          </ThreadPrimitive.ScrollToBottom>
        </ThreadPrimitive.Viewport>

        <ComposerPrimitive.Root className="m-4 mt-0 flex items-end gap-3 rounded-xl border border-base-content/15 bg-base-100 p-3 focus-within:ring-2 focus-within:ring-primary/40">
          <ComposerPrimitive.Input
            aria-label="Message"
            placeholder="Write a message…"
            disabled={!adapter}
            className="max-h-40 min-h-12 flex-1 resize-none bg-transparent px-1 py-2 text-sm outline-none disabled:cursor-not-allowed disabled:opacity-50"
          />
          <AuiIf condition={(s) => !s.thread.isRunning}>
            <ComposerPrimitive.Send
              disabled={!adapter}
              className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Send
            </ComposerPrimitive.Send>
          </AuiIf>
          <AuiIf condition={(s) => s.thread.isRunning}>
            <ComposerPrimitive.Cancel className="rounded-lg border border-base-content/20 px-4 py-2 text-sm transition hover:bg-base-200">
              Stop
            </ComposerPrimitive.Cancel>
          </AuiIf>
        </ComposerPrimitive.Root>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

function UserMessage() {
  return (
    <MessagePrimitive.Root className="ml-auto max-w-[85%] rounded-2xl bg-base-200 px-4 py-3 text-sm leading-relaxed">
      <MessagePrimitive.Parts />
    </MessagePrimitive.Root>
  );
}

function AssistantMessage() {
  return (
    <MessagePrimitive.Root className="mr-auto max-w-[90%] text-sm leading-relaxed">
      <MessagePrimitive.Parts />
      <MessagePrimitive.Error>
        <p role="alert" className="mt-2 text-error">
          Unable to get a response. Please try again.
        </p>
      </MessagePrimitive.Error>
    </MessagePrimitive.Root>
  );
}
