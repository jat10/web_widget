/** Resolve presentation URLs without allowing executable schemes or credentials. */
export function stylesheetURL(value: unknown, base?: string): string {
  if (typeof value !== "string" || !value.trim() || /[\\\s]/.test(value)) {
    throw new Error("stylesheet-url must be a nonblank HTTP(S) URL without credentials.");
  }
  let url: URL;
  try { url = new URL(value, base); }
  catch { throw new Error("Invalid stylesheet-url."); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("stylesheet-url must use HTTP(S) without credentials.");
  }
  return url.href;
}
