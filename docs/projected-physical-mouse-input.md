# Independently projected physical mouse input

## Evidence

The 2026-10-02 phone diagnostic (1.2.20/1002020) detected external display
1010 and continuously decoded/presented video, but all 79 projected pointer
intervals had zero native and ArkUI mouse moves. Mouse-marked compatibility
touches and click packets did arrive. Some compatibility releases were followed
by a second click from the click-only fallback. This narrows the problem to
input reception/routing; it does not prove that the system routes a phone-bound
USB mouse into the external window.

## Changes

- Only for an independently projected window, the input capture uses transparent
  hit testing and the native surface participates in hit testing. The viewport
  parent also handles bubbling mouse events. Local/mirrored use retains its
  previous input hit-test modes.
- The library-backed XComponent uses its native C mouse callbacks, not an ArkTS
  onMouse callback that the component does not support in this configuration.
- Native component pixels are normalized using the owning surface dimensions,
  avoiding reliance on the phone's density for a TV display.
- Matching action/position deliveries are paired across native, capture,
  viewport and compatibility paths in either order. Distinct subsequent moves,
  button edges and same-source fast clicks remain distinct.
- A compatibility Down/Up sequence still suppresses a second click when focus
  or hover cleanup released the held button before Up. A true click-only/orphan
  event retains its fallback.
- Diagnostics add viewport move counts, event target display, capture focus,
  input-route selection and native surface dimensions. No global input monitor
  or new permission is requested.

## Device acceptance (not yet completed)

1. Independently project the app to the TV and connect the wired mouse to the
   phone. Move without pressing a button: the remote cursor and hover highlights
   should track movement.
2. Test a single click, fast double-click, left-button drag, right click, and
   scrolling. One single click must not open a file as a double-click.
3. Repeat after fullscreen, resizing, zoom, display switch, and disconnecting the
   cable. Check ordinary tablet/PC mouse and phone touch still work.
4. Export diagnostics. At least one native/ArkUI/viewport reception counter
   should increase while moving. If all three remain zero despite actual mouse
   motion, investigate system display/window input routing rather than claiming
   the remote cursor rendering fix solved the problem.

Automated tests and a successful build do not replace this wired-device test.
