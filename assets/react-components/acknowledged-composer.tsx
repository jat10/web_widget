import { ComposerPrimitive, useAuiState } from "@assistant-ui/react";

type Props = {
  ready: boolean; busy: boolean; sending: boolean; draftLocked: boolean;
  onSend: () => void; placeholder: string; maxLength: number;
  labels: { input: string; send: string; sending: string; working: string; sendMessage: string };
};

export function AcknowledgedComposer({ ready, busy, sending, draftLocked, onSend, placeholder, maxLength, labels }: Props) {
  const empty = useAuiState(state => !state.composer.text.trim());
  return <ComposerPrimitive.Root className="zaq-composer" onSubmit={event => {
    event.preventDefault();
    if (!busy && ready && !empty) onSend();
  }}>
    <ComposerPrimitive.Input aria-label={labels.input} placeholder={placeholder} maxLength={maxLength}
      className="zaq-composer-input" disabled={draftLocked} onKeyDown={event => {
        if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
          event.preventDefault();
          if (!busy && ready && !empty) onSend();
        }
      }} />
    <button type="submit" className="zaq-composer-send" disabled={busy || empty || !ready} aria-label={labels.sendMessage}>
      {sending && ready ? labels.sending : busy && ready ? labels.working : labels.send}
    </button>
  </ComposerPrimitive.Root>;
}
