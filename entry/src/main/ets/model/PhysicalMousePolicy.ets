// Match an actual native/ArkUI event pair, not every event in a time window.
// A native button event must never swallow later ArkUI-only movement.
interface ProjectedPointerDelivery {
  action: number;
  x: number;
  y: number;
  at: number;
  origins: number;
}

export class PhysicalMouseDeduplicator {
  private action: number = -1;
  private x: number = 0;
  private y: number = 0;
  private at: number = 0;
  private projected: ProjectedPointerDelivery[] = [];

  clear(): void { this.action = -1; this.projected = []; }

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
    this.action = -1;
    return duplicate;
  }

  // Projected input can reach ArkUI before the queued native callback, or
  // arrive as mouse-to-touch compatibility input. Match across origins only.
  consumeProjectedDuplicate(action: number, x: number, y: number, now: number, origin: number): boolean {
    if (action < 0 || !Number.isFinite(x) || !Number.isFinite(y)) return false;
    this.projected = this.projected.filter((sample: ProjectedPointerDelivery) =>
      now >= sample.at && now - sample.at < 80);
    for (const sample of this.projected) {
      if (sample.action === action && (sample.origins & origin) === 0 &&
        Math.abs(sample.x - x) <= 0.5 && Math.abs(sample.y - y) <= 0.5) {
        sample.origins |= origin;
        return true;
      }
    }
    this.projected.push({ action, x, y, at: now, origins: origin });
    if (this.projected.length > 32) this.projected.shift();
    return false;
  }
}

export function isTouchOnlyMouseEvent(touchSource: boolean, mouseSource: boolean,
  pointerTool: boolean, touchTool: boolean): boolean {
  // Projection can wrap a physical mouse in a touch-compatible source. Explicit
  // hardware tool/source information takes precedence over that wrapper.
  return !mouseSource && !pointerTool && (touchSource || touchTool);
}
