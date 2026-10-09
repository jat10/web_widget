type ConnectionState = {
  ready: boolean;
  banner: "reconnecting" | null;
};

// Presentation state belongs to this iframe document, not a LiveView process.
let state: ConnectionState = { ready: true, banner: null };
let terminal = false;
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

export function connectionLost() {
  if (!state.ready || terminal) return;
  clearTimers();
  publish({ ready: false, banner: null });
  timers.push(window.setTimeout(() => publish({ ...state, banner: "reconnecting" }), 2000));
}

export function connectionReady() {
  if (state.ready || terminal) return;
  clearTimers();
  publish({ ready: true, banner: null });
}

export function connectionRevoked() {
  terminal = true;
  clearTimers();
  publish({ ready: false, banner: null });
}
