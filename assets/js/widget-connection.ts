type ConnectionState = {
  ready: boolean;
  banner: "reconnecting" | "connected" | null;
  canRetry: boolean;
};

// Presentation state belongs to this iframe document, not a LiveView process.
let state: ConnectionState = { ready: true, banner: null, canRetry: false };
let terminal = false;
let retry: (() => void) | undefined;
const listeners = new Set<() => void>();
let timers: number[] = [];

const publish = (next: ConnectionState) => {
  state = next;
  listeners.forEach(listener => listener());
};
const clearTimers = () => {
  timers.forEach(timer => window.clearTimeout(timer));
  timers = [];
};

export const connectionSnapshot = () => state;
export const subscribeConnection = (listener: () => void) => {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
};
export const configureConnectionRetry = (callback: () => void) => { retry = callback; };
export const retryConnection = () => { if (state.canRetry && !terminal) retry?.(); };

export function connectionLost() {
  if (!state.ready || terminal) return;
  clearTimers();
  publish({ ready: false, banner: null, canRetry: false });
  timers.push(window.setTimeout(() => publish({ ...state, banner: "reconnecting" }), 2000));
  timers.push(window.setTimeout(() => publish({ ...state, canRetry: true }), 15000));
}

export function connectionReady() {
  if (state.ready || terminal) return;
  const showRestored = state.banner === "reconnecting";
  clearTimers();
  publish({ ready: true, banner: showRestored ? "connected" : null, canRetry: false });
  if (showRestored) {
    timers.push(window.setTimeout(() => publish({ ...state, banner: null }), 2000));
  }
}

export function connectionRevoked() {
  terminal = true;
  clearTimers();
  publish({ ready: false, banner: null, canRetry: false });
}
