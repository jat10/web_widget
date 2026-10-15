type ProgressMessage = { role: string; status?: string };

export function WorkingIndicator({ label }: { label: string }) {
  return <div className="zaq-working" role="status"><span className="zaq-working-dots" aria-hidden="true"><i /><i /><i /></span><span>{label}</span></div>;
}

export function ConversationProgress({ isTyping, messages, label }: { isTyping: boolean; messages: readonly ProgressMessage[]; label: string }) {
  if (!isTyping || messages.some(message => message.role === "assistant" && message.status === "running")) return null;
  return <WorkingIndicator label={label} />;
}
