import { useAuiState } from "@assistant-ui/react";

export function WorkingIndicator({ label }: { label: string }) {
  return <div className="zaq-working" role="status"><span className="zaq-working-dots" aria-hidden="true"><i /><i /><i /></span><span>{label}</span></div>;
}

export function ConversationProgress({ isTyping, label }: { isTyping: boolean; label: string }) {
  const hasRunningAssistant = useAuiState(state => state.thread.messages.some(message =>
    message.role === "assistant" && message.status?.type === "running" && message.metadata.isOptimistic !== true));
  if (!isTyping || hasRunningAssistant) return null;
  return <WorkingIndicator label={label} />;
}
