import AppKit
import WebKit

/// An interactive utility panel, not a second meeting or assistant process.
@MainActor
final class ContextPanel: NSPanel {
  init(content: NSView, near main: NSWindow) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 390, height: 600),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    title = "Aside · Context"
    contentView = content
    minSize = NSSize(width: 330, height: 340)
    isReleasedWhenClosed = false
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
    isOpaque = false
    alphaValue = 0.94
    backgroundColor = .windowBackgroundColor
    hasShadow = true
    animationBehavior = .utilityWindow
    tabbingMode = .disallowed
    standardWindowButton(.zoomButton)?.isHidden = true
    // Omitted the generic panel in the tested full-display ScreenCaptureKit harness.
    // Other capturing processes and sharing modes still require their own test.
    sharingType = .none
    if !setFrameUsingName("AsideContextPanel"), let screen = main.screen ?? NSScreen.main {
      let available = screen.visibleFrame
      setFrameOrigin(
        NSPoint(x: available.maxX - frame.width - 18, y: available.maxY - frame.height - 36))
    }
    if let screen = main.screen ?? NSScreen.main {
      setFrame(constrainFrameRect(frame, to: screen), display: false)
    }
    setFrameAutosaveName("AsideContextPanel")
  }
  static func interfaceURL(root: URL) -> URL {
    var parts = URLComponents(
      url: root.appendingPathComponent("index.html").absoluteURL,
      resolvingAgainstBaseURL: true)!
    parts.fragment = "context"
    return parts.url!
  }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A nonactivating panel should respond to its first click, including docking or stopping capture.
@MainActor
final class ContextWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
