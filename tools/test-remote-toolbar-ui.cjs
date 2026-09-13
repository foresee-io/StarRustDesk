const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '..')
const remotePage = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/RemotePage.ets'),
  'utf8'
)
const theme = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/theme/RustDeskTheme.ets'),
  'utf8'
)

function expect(source, pattern, message) {
  if (!pattern.test(source)) {
    throw new Error(message)
  }
}

expect(theme, /CONTROL_SELECTED_BG:\s*ResourceColor\s*=\s*'#DCEBFF'/,
  'light toolbar selection background must use the approved pale blue')
expect(theme, /CONTROL_SELECTED_TEXT:\s*ResourceColor\s*=\s*'#246BCE'/,
  'light toolbar selection text must remain readable blue')
expect(remotePage, /@State remoteToolbarCollapsed:\s*boolean\s*=\s*false/,
  'remote toolbar must support a collapsed state')
expect(remotePage, /buildFloatingToolbar\(\)[\s\S]*Text\('控'\)[\s\S]*setFloatingPanelCollapsed\(false, false\)/,
  'collapsed remote toolbar must expose a compact restore button')
expect(remotePage, /beginRemoteToolbarDrag\(\)[\s\S]*updateRemoteToolbarDrag\(offsetX:\s*number,\s*offsetY:\s*number\)/,
  'remote toolbar must support bounded dragging')
expect(remotePage, /controlSelectedBackgroundColor\(\)[\s\S]*CONTROL_SELECTED_BG_DARK[\s\S]*CONTROL_SELECTED_BG/,
  'selected toolbar colors must adapt to dark mode')
expect(remotePage, /display === this\.currentDisplay[\s\S]*controlSelectedBackgroundColor\(\)/,
  'the current remote display must use the pale-blue selected style')
expect(remotePage, /edgeAutoPanEnabled \? this\.controlSelectedBackgroundColor\(\)/,
  'edge following must use the pale-blue selected style')
expect(remotePage, /selected \? this\.controlSelectedBackgroundColor\(\) : this\.mutedSurfaceColor\(\)/,
  'general selected toolbar buttons must use the pale-blue selected style')
expect(remotePage, /按钮变为淡蓝色/,
  'gesture help must describe the new selected state')
expect(remotePage, /Button\(`屏\$\{display \+ 1\}`\)[\s\S]*?\.width\(vertical \? 80 : 44\)/,
  'phone display buttons must stay compact enough to avoid a clipped keyboard button')
expect(remotePage, /item === 'input'[\s\S]*buildInputModeButton\(vertical \? 80 : 56, vertical, item\)/,
  'the dynamic toolbar must preserve the compact phone input-mode button')
expect(remotePage, /item === 'keyboard'[\s\S]*buildToolbarButton\('键盘', vertical \? 80 : 56/,
  'the dynamic toolbar must preserve the compact phone keyboard button')
expect(remotePage, /height - this\.getRemoteToolbarHeight\(\) - 18/,
  'floating toolbar must keep a safe gap above the system navigation area')
expect(remotePage, /isHandheldLandscape\(\)[\s\S]*deviceInfo\.deviceType === 'phone' \|\| deviceInfo\.deviceType === 'tablet'/,
  'phone and tablet landscape layouts must be detected explicitly')
expect(remotePage, /getKeyboardToolsBaseX\(\)[\s\S]*isHandheldLandscape\(\)\) return 8/,
  'the keyboard toolbar must default to the top-left in handheld landscape')
expect(remotePage, /getRemoteToolbarBaseX\(\)[\s\S]*width - this\.getRemoteToolbarCurrentWidth\(\) - 8/,
  'the control toolbar must default to the top-right in handheld landscape')
expect(remotePage, /buildControlToolbarItems\(true\)[\s\S]*ScrollDirection\.Vertical/,
  'the landscape control toolbar must expand downward')
expect(remotePage, /buildKeyboardToolbarItems\(true\)[\s\S]*ScrollDirection\.Vertical/,
  'the landscape keyboard toolbar must expand downward')
expect(remotePage, /LongPressGesture\(\{ repeat: false, duration: 550 \}\)[\s\S]*openToolbarOrderEditor/,
  'toolbar buttons must expose long-press ordering')
expect(remotePage, /getOption\('show-virtual-mouse'\)[\s\S]*setOption\('show-virtual-mouse'/,
  'the RustDesk-style virtual mouse preference must be toggleable')
expect(remotePage, /control-\$\{item\}[\s\S]*showVirtualMouse \? 1 : 0/,
  'the control toolbar key must refresh when virtual mouse visibility changes')
expect(remotePage, /this\.showVirtualMouse[\s\S]*this\.isHandheldDevice\(\)[\s\S]*this\.buildVirtualMouseOverlay\(\)/,
  'the RustDesk-style virtual mouse must render only on handheld devices')
expect(remotePage, /showVirtualMouse[\s\S]*canPanViewport\(\)[\s\S]*handleViewportPan\(event\)/,
  'the zoomed background must pan while the virtual mouse controls the remote pointer')
expect(remotePage, /buildRemoteViewportWithQualityMonitor\(\)[\s\S]*buildRemoteViewport\(\)[\s\S]*buildVirtualMouseOverlay\(\)/,
  'the virtual mouse must share the remote viewport coordinate system')
expect(remotePage, /updatePointerFromVirtualMouse\(\)[\s\S]*visualPointToRemote\([\s\S]*virtualMouseX[\s\S]*virtualMouseY/,
  'virtual mouse movement must use absolute viewport-to-remote mapping')
expect(remotePage, /applyRemoteCursorPosition[\s\S]*alignVirtualMouseToRemotePosition\(cursor\.x, cursor\.y\)/,
  'authoritative remote cursor samples must recalibrate the virtual mouse')
expect(remotePage, /updateVirtualMouseMove[\s\S]*updatePointerFromVirtualMouse\(\)/,
  'virtual mouse dragging must not reuse accelerated touchpad deltas')
expect(remotePage, /handleVirtualMouseButtonTouch[\s\S]*TouchType\.Move[\s\S]*VIRTUAL_MOUSE_BUTTON_DRAG_THRESHOLD[\s\S]*beginVirtualMouseButtonDrag[\s\S]*TouchType\.Up[\s\S]*clickVirtualMouseButton/,
  'virtual mouse buttons must distinguish taps from drag selection in one touch path')
expect(remotePage, /Button\('左键'[\s\S]*?handleVirtualMouseButtonTouch\('left'[\s\S]*?Button\('右键'[\s\S]*?handleVirtualMouseButtonTouch\('right'/,
  'both virtual mouse buttons must use the conflict-free touch handler')
expect(remotePage, /clickVirtualMouseButtonFallback[\s\S]*virtualMouseLastTouchResolvedAt[\s\S]*clickVirtualMouseButton[\s\S]*handleVirtualMouseButtonTouch\('left'[\s\S]*clickVirtualMouseButtonFallback\('left'/,
  'virtual mouse buttons must provide a deduplicated click fallback')
expect(remotePage, /handleVirtualMouseWheelTouch[\s\S]*virtualMouseWheelTouchMoved[\s\S]*sendVirtualMouseWheel[\s\S]*clickVirtualMouseButton\('middle'\)/,
  'the center wheel must distinguish scrolling from a middle click')
expect(remotePage, /VIRTUAL_MOUSE_WHEEL_BUTTON_STEP:\s*number\s*=\s*3[\s\S]*sendVirtualMouseWheel/,
  'virtual wheel buttons must send a visible multi-step scroll')
expect(remotePage, /Button\('⌄'\)[\s\S]*?\.position\(\{ x: 29, y: 0 \}\)[\s\S]*?\.zIndex\(2\)/,
  'virtual wheel controls must stay above the overlapping mouse drag body')
expect(remotePage, /setKeyboardAvoidMode\(KeyboardAvoidMode\.RESIZE\)/,
  'the keyboard must resize the remote viewport instead of covering landscape content')

console.log('PASS remote toolbar, virtual mouse, landscape placement and ordering controls')
