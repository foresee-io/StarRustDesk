// Match an actual native/ArkUI event pair, not every event in a time window.
// A native button event must never swallow later ArkUI-only movement.
export class PhysicalMouseDeduplicator {
  private action: number = -1;
  private x: number = 0;
  private y: number = 0;
  private at: number = 0;

  clear(): void { this.action = -1; }

  rememberNative(action: number, x: number, y: number, at: number): void {
    this.action = Number.isFinite(x) && Number.isFinite(y) ? action : -1;
    this.x = x;
    this.y = y;
    this.at = at;
  }

  consumeDuplicate(action: number, x: number, y: number, now: number): boolean {
    const duplicate: boolean = action >= 0 && action === this.action &&
      now >= this.at && now - this.at < 80 &&
      Math.abs(x - this.x) < 0.01 && Math.abs(y - this.y) < 0.01;
    // Never reuse a stale native sample after a different ArkUI event.
    this.clear();
    return duplicate;
  }
}

export function isTouchOnlyMouseEvent(touchSource: boolean, mouseSource: boolean,
  pointerTool: boolean, touchTool: boolean): boolean {
  // Projection can wrap a physical mouse in a touch-compatible source. Explicit
  // hardware tool/source information takes precedence over that wrapper.
  return !mouseSource && !pointerTool && (touchSource || touchTool);
}
