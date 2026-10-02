# Fullscreen transition fix (2026-09-21)

## Evidence and scope

The reported tablet recording and 20260921-205944 diagnostic log show container
height alternating between 800 and 866 at width 1318. The remote frame is
2560x1440, so both layouts fit the video at 1318x741.375. Recreating the
XComponent and rebinding the native window on each toggle unnecessarily
released the H.265 decoder and waited for another keyframe.

The fullscreen toolbar used value parameters in a nested ArkUI builder, leaving
the displayed label/selection stale despite the underlying state changing.

## Changes

- One stable viewport/XComponent branch across fullscreen and normal layouts.
- Fullscreen buttons observe state directly, show transition progress and reject
  duplicate clicks. API failures restore the prior UI state and show a toast.
- Main-window layout and system-bar operations are awaited in a shared queue.
  Page cleanup follows in-flight operations and cannot re-enter fullscreen on
  failure. No `getLastWindow` selection of transient subwindows.
- Rebind decisions use fitted video dimensions and surface identity, not the
  letterbox/container dimensions. True rotation, target replacement and explicit
  recovery retain the safe rebind path.
- A resize that settles to its original target resumes the paused CPU writer
  without recreating its native window or decoder.
- Diagnostic events cover requests, each window API, rollback/cleanup, elapsed
  time, actual dimensions, reused layouts and rebind results. Existing diagnostic
  opt-in still applies; no identifiers, passwords or content were added.

## Automated verification

Run `tools/test-fullscreen-transition.cjs`: 19 cases cover layout reuse, real
resize/target changes, coalescing, initial bind, forced recovery, button state,
duplicate clicks, API failure, queued cleanup and missing main windows.
Run all `tools/test-*.cjs` and build the debug HAP with the configured DevEco SDK.

## Real-device acceptance still required

1. On the affected landscape tablet, enter/exit fullscreen repeatedly. Check
   label/selection, status/navigation bars and uninterrupted video; no repeated
   `xcomponent_ready`/decoder release should occur for a viewport-only change.
2. Repeat with H.265 hardware and VP9 software video, preserving source aspect
   ratio and zoom. Fullscreen does not mean stretching/cropping away letterboxing.
3. Rotate, switch remote displays and reopen the app; genuine target/size changes
   must still render correctly with aligned input/cursor coordinates.
4. Disconnect/leave during a pending toggle and reconnect immediately. System
   bars must be restored; an old promise must not affect the new page.

This fix does not change the app version, connection protocol, decoder selection
or release artifacts, and does not establish device acceptance by itself.
