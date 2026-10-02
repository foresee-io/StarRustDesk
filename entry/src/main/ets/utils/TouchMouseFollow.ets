export interface TouchFollowAxis {
  pointer: number;
  offset: number;
}

// Mobile cursor/canvas coupling, following CursorModel.updatePan in RustDesk.
// Input is visual pixels; output pointer is display-local remote pixels.
// Consume movement up to the visible center first, then move the canvas. At
// the real desktop boundary, remaining movement belongs to the cursor again.
export function followTouchMouseAxis(pointer: number, delta: number, scale: number,
  remoteSize: number, viewportSize: number, imageStart: number, offset: number,
  panLimit: number): TouchFollowAxis {
  if (!Number.isFinite(delta) || !Number.isFinite(scale) || scale <= 0 ||
    remoteSize <= 0 || viewportSize <= 0) return { pointer: pointer, offset: offset };
  const next: number = Math.max(0, Math.min(remoteSize - 1, pointer + delta / scale));
  const movement: number = (next - pointer) * scale;
  if (Math.abs(movement) < 0.0001 || panLimit <= 0) return { pointer: next, offset: offset };
  const visual: number = imageStart + pointer * scale;
  const nextVisual: number = imageStart + next * scale;
  const center: number = viewportSize / 2;
  let pan: number = 0;
  if (visual < 0 || visual > viewportSize) {
    // Zoom/manual panning can leave the pointer offscreen. Reveal it on the
    // next non-zero gesture without warping the remote pointer's coordinates.
    pan = nextVisual - center;
  } else if (movement > 0 && nextVisual > center) {
    pan = Math.min(movement, nextVisual - center);
  } else if (movement < 0 && nextVisual < center) {
    pan = Math.max(movement, nextVisual - center);
  }
  return { pointer: next, offset: Math.max(-panLimit, Math.min(panLimit, offset - pan)) };
}
