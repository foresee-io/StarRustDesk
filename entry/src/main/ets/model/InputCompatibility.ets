// Preferences are scoped to server + peer; identical IDs on different servers must not collide.
export function inputCompatibilityKey(server: string, peer: string, name: string): string {
  return `input-compat-${encodeURIComponent(server.trim().toLowerCase())}-${encodeURIComponent(peer)}-${name}`;
}

export function selectedKeyboardMode(value: string): number {
  return value === '1' ? 1 : (value === '2' ? 2 : 0);
}

export function selectedCursorMode(value: string): string {
  return value === 'embedded' || value === 'separate' ? value : 'auto';
}

export function shouldSuppressCursor(mode: string, oneKvm: boolean): boolean {
  return mode === 'embedded' || (mode === 'auto' && oneKvm);
}
