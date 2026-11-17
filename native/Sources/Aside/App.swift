import AppKit
import WebKit
import os

@main
struct AsideMain {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
  WKNavigationDelegate, NSWindowDelegate
{
  private var window: NSWindow!
  private var webView: WKWebView!
  private var contextPanel: ContextPanel?
  private var contextWebView: WKWebView?
  private var controller: AppController!
  private var resourceRoot: URL!
  private let logger = Logger(subsystem: "local.aside.meeting", category: "interface")
  private var presentedLoadError = false
  private var pendingState: AppState?
  private var stateDeliveryTask: Task<Void, Never>?
  func applicationDidFinishLaunching(_ notification: Notification) {
    do { controller = try AppController() } catch {
      let alert = NSAlert()
      alert.messageText = "Aside could not open its local data"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "aside")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self
    webView.setValue(false, forKey: "drawsBackground")
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Aside"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 1000, height: 680)
    window.contentView = webView
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    installMenu()
    controller.onState = { [weak self] state in self?.scheduleState(state) }
    controller.onRecordingTick = { [weak self] id, duration, runtime in
      self?.flushPendingState()
      self?.send(RecordingTickEvent(meetingID: id, duration: duration, runtime: runtime))
    }
    resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("web")
    if let override = ProcessInfo.processInfo.environment["ASIDE_WEB_DIR"] {
      resourceRoot = URL(fileURLWithPath: override)
    }
    guard let resourceRoot,
      FileManager.default.fileExists(atPath: resourceRoot.appendingPathComponent("index.html").path)
    else {
      webView.loadHTMLString(
        "<h1>Aside</h1><p>The compiled interface is missing. Build the app with scripts/build-macos.sh.</p>",
        baseURL: nil)
      return
    }
    webView.loadFileURL(
      resourceRoot.appendingPathComponent("index.html"), allowingReadAccessTo: resourceRoot)
  }
  private func installMenu() {
    let menu = NSMenu()
    let item = NSMenuItem()
    menu.addItem(item)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Aside", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Aside", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = appMenu
    let edit = NSMenuItem()
    menu.addItem(edit)
    let editMenu = NSMenu(title: "Edit")
    edit.submenu = editMenu
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let viewItem = NSMenuItem()
    menu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewItem.submenu = viewMenu
    let floating = viewMenu.addItem(
      withTitle: "Floating help", action: #selector(toggleContextWindow(_:)), keyEquivalent: "p")
    floating.keyEquivalentModifierMask = [.command, .shift]
    floating.target = self
    let dock = viewMenu.addItem(
      withTitle: "Return help to sidebar", action: #selector(dockContextWindow(_:)),
      keyEquivalent: "")
    dock.target = self
    viewMenu.addItem(.separator())
    let visibility = viewMenu.addItem(
      withTitle: "Test capture visibility…", action: #selector(testCaptureVisibility(_:)),
      keyEquivalent: "")
    visibility.target = self
    NSApp.mainMenu = menu
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame,
      let body = message.body as? [String: Any], let id = body["id"] as? String,
      let action = body["action"] as? String
    else { return }
    let payload = body["payload"] as? [String: Any] ?? [:]
    let origin = message.webView
    Task {
      do {
        if action == "inspectTranscriptSource" {
          guard let object = payload["source"] as? [String: Any] else {
            throw AsideError("A transcript citation is required")
          }
          let source = try JSONDecoder().decode(
            Source.self, from: JSONSerialization.data(withJSONObject: object))
          let evidence = try controller.transcriptEvidence(for: source)
          send(EvidenceReply(id: id, result: evidence), to: origin)
          return
        }
        let state: AppState?
        switch action {
        case "openSystemAudioSettings":
          guard
            let url = URL(
              string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
          else { throw AsideError("Could not open recording permissions") }
          NSWorkspace.shared.open(url)
          state = controller.state
        case "floatContext":
          try showContextWindow()
          state = controller.state
        case "dockContext":
          dockContextWindow(nil)
          state = controller.state
        case "hideContext":
          contextPanel?.orderOut(nil)
          state = controller.state
        case "showMainWindow":
          showMainWindow()
          state = controller.state
        case "showMeetingContext":
          showMainWindow()
          webView.evaluateJavaScript(
            "window.dispatchEvent(new Event('aside-open-context'))", completionHandler: nil)
          state = controller.state
        case "showTranscriptSource":
          guard let source = payload["source"] else {
            throw AsideError("Choose a source passage first")
          }
          let data = try JSONSerialization.data(withJSONObject: source)
          let json = String(decoding: data, as: UTF8.self)
          showMainWindow()
          webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('aside-inspect-source',{detail:\(json)}))",
            completionHandler: nil)
          state = controller.state
        default:
          state = try await controller.handle(action: action, payload: payload)
        }
        if let state {
          cancelPendingState()
          send(StateEvent(state: state))
        }
        send(BridgeReply(id: id, result: state, error: nil), to: origin)
      } catch {
        controller.reportError(error)
        send(BridgeReply(id: id, result: nil, error: error.localizedDescription), to: origin)
      }
    }
  }
  // Coalesce bursts of complete snapshots; action replies and recording ticks stay immediate.
  private func scheduleState(_ state: AppState) {
    pendingState = state
    guard stateDeliveryTask == nil else { return }
    stateDeliveryTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      guard let self else { return }
      flushPendingState()
    }
  }
  private func flushPendingState() {
    let snapshot = pendingState
    cancelPendingState()
    if let snapshot { send(StateEvent(state: snapshot)) }
  }
  private func cancelPendingState() {
    stateDeliveryTask?.cancel()
    stateDeliveryTask = nil
    pendingState = nil
  }
  private func send<T: Encodable>(_ object: T, to target: WKWebView? = nil) {
    guard let data = try? JSONEncoder().encode(object),
      let json = String(data: data, encoding: .utf8)
    else { return }
    let destinations: [WKWebView] =
      target.map { [$0] }
      ?? [webView, contextWebView].compactMap { $0 }
    for destination in destinations {
      destination.evaluateJavaScript(
        "window.__asideReceive && window.__asideReceive(\(json));", completionHandler: nil)
    }
  }
  private func showContextWindow() throws {
    if contextPanel == nil {
      guard let resourceRoot else { throw AsideError("The bundled interface is unavailable") }
      let configuration = WKWebViewConfiguration()
      configuration.userContentController.add(self, name: "aside")
      let floatingWeb = ContextWebView(frame: .zero, configuration: configuration)
      floatingWeb.navigationDelegate = self
      floatingWeb.setValue(false, forKey: "drawsBackground")
      let panel = ContextPanel(content: floatingWeb, near: window)
      panel.delegate = self
      contextWebView = floatingWeb
      contextPanel = panel
      floatingWeb.loadFileURL(
        ContextPanel.interfaceURL(root: resourceRoot),
        allowingReadAccessTo: resourceRoot.absoluteURL)
    }
    controller.setContextFloating(true)
    contextPanel?.makeKeyAndOrderFront(nil)
    send(StateEvent(state: controller.state))
  }
  private func showMainWindow() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func toggleContextWindow(_ sender: Any?) {
    if contextPanel?.isVisible == true {
      contextPanel?.orderOut(nil)
    } else {
      do { try showContextWindow() } catch { controller.reportError(error) }
    }
  }
  @objc private func dockContextWindow(_ sender: Any?) {
    contextPanel?.close()
    controller.setContextFloating(false)
    showMainWindow()
  }
  @objc private func testCaptureVisibility(_ sender: Any?) {
    do { try showContextWindow() } catch {
      controller.reportError(error)
      return
    }
    guard let contextPanel else { return }
    Task {
      let alert = NSAlert()
      alert.messageText = "Floating help capture test"
      do {
        let report = try await ContextCaptureProbe.run(panel: contextPanel)
        try? controller.store.write(
          report, to: controller.store.root.appendingPathComponent("context-capture-test.json"))
        alert.informativeText = report.explanation
      } catch {
        alert.informativeText = "The capture test could not finish: " + error.localizedDescription
      }
      alert.runModal()
    }
  }
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === contextPanel {
      controller.setContextFloating(false)
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showMainWindow()
    return true
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.isFileURL, let root = resourceRoot,
      url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    logger.info("Bundled meeting interface finished navigation")
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    presentLoadError(error)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { presentLoadError(error) }
  private func presentLoadError(_ error: Error) {
    logger.error(
      "Bundled interface navigation failed: \(error.localizedDescription, privacy: .public)")
    guard !presentedLoadError else { return }
    presentedLoadError = true
    let alert = NSAlert()
    alert.messageText = "Aside could not load its interface"
    alert.informativeText =
      "Your local recordings and notes are retained. Rebuild the app with scripts/build-macos.sh, then reopen it.\n\n"
      + error.localizedDescription
    alert.beginSheetModal(for: window)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Hiding or closing the little window never ends an active recording.
    !controller.state.runtime.recording && contextPanel?.isVisible != true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard controller != nil else { return .terminateNow }
    Task {
      await controller.shutdown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
private struct BridgeReply: Encodable {
  var id: String
  var result: AppState?
  var error: String?
}
private struct StateEvent: Encodable {
  var event = "state"
  var state: AppState
}

private struct RecordingTickEvent: Encodable {
  var event = "recordingTick"
  var meetingID: String
  var duration: Double
  var runtime: RuntimeState
}

private struct EvidenceReply: Encodable {
  var id: String
  var result: TranscriptEvidence
}
