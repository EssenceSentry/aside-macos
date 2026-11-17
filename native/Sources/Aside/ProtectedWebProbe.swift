import AVFoundation
import AppKit
import WebKit

struct ProtectedWebProbeReport: Codable, Sendable {
  var sourceSnapshotMarkerHits = 0
  var sourceSnapshots = 0
  var sourceOnly: CaptureProbeSamples?
  var clearPresentation: CaptureProbeSamples?
  var protectedPresentation: CaptureProbeSamples?
  var afterPresentationRemoval: CaptureProbeSamples?
  var rendererStates: [CaptureProbeRenderer] = []
  var sourceOpacityRemainedZero = true
  var nativeHitTestRoutesToWeb = false
  var nativeInteractionTested = false
  var error: String?
  var summary: String {
    let passed =
      error == nil && sourceSnapshots > 0 && sourceSnapshotMarkerHits == sourceSnapshots
      && sourceOpacityRemainedZero && sourceOnly?.ocrComplete == true && sourceOnly?.markerHits == 0
      && clearPresentation?.ocrComplete == true && clearPresentation?.markerHits == 3
      && clearPresentation?.changingMarkerHits == 3
      && protectedPresentation?.ocrComplete == true && protectedPresentation?.markerHits == 0
      && afterPresentationRemoval?.ocrComplete == true && afterPresentationRemoval?.markerHits == 0
      && rendererStates.count == 2 && rendererStates.allSatisfy(\.valid)
    return passed
      ? "Generic web snapshot text controls passed. This does not establish an invisible window: its ordinary background may remain. Local protected pixels and native mouse/keyboard interaction are UNVERIFIED. This is not installed for real contextual content."
      : "Generic web snapshot prototype is INCONCLUSIVE or failed a control; real contextual content remains unchanged."
  }
}

/// Isolated public-API experiment. No real state, URLs, bridge, navigation or meeting data.
@MainActor
enum ProtectedWebProbe {
  static func run(panel: NSPanel, session: CaptureProbeSession) async throws
    -> ProtectedWebProbeReport
  {
    let previous = panel.contentView
    let fixture = ProtectedWebFixture(
      frame: previous?.bounds ?? NSRect(x: 0, y: 0, width: 390, height: 600))
    panel.contentView = fixture
    defer {
      fixture.removePresentation()
      panel.contentView = previous
    }
    var report = ProtectedWebProbeReport()
    fixture.web.loadHTMLString(
      """
      <!doctype html><html><meta name="viewport" content="width=device-width,initial-scale=1">
      <style>body{font:18px system-ui;background:white;color:black;padding:12px;margin:0}h1{font-size:22px}textarea{width:90%;height:70px}button{padding:12px}.space{height:750px}</style>
      <h1 id="marker">ASIDE WEB TEST 701</h1>
      <button id="button" onclick="this.textContent='Clicked '+(++window.clickCount)">Click counter</button>
      <textarea aria-label="Generic input" placeholder="Generic typing test only"></textarea>
      <p>Scroll the generic fixture. No real meeting data.</p><div class="space"></div><p id="end">End of generic scroll test</p>
      <script>window.clickCount=0;window.fixtureReady=true;</script></html>
      """, baseURL: nil)
    do {
      var ready = false
      for _ in 0..<60 {
        if (try? await fixture.web.evaluateJavaScript("window.fixtureReady === true")) as? Bool
          == true
        {
          ready = true
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard ready else { throw AsideError("Generic web fixture did not finish loading") }
      // Hit testing checks the real native hierarchy, not a JavaScript click simulation.
      if let hit = fixture.hitTest(NSPoint(x: 50, y: fixture.bounds.height - 100)) {
        report.nativeHitTestRoutesToWeb = hit === fixture.web || hit.isDescendant(of: fixture.web)
      }
      report.sourceOnly = try await session.samples(
        stage: "web-source-only", marker: "ASIDE WEB TEST"
      ) { index in
        try await fixture.setMarker(index)
        let image = try await fixture.snapshot()
        report.sourceSnapshots += 1
        if try CaptureProbeSupport.contains(image, marker: "ASIDE WEB TEST \(701 + index)") {
          report.sourceSnapshotMarkerHits += 1
        }
        report.sourceOpacityRemainedZero =
          report.sourceOpacityRemainedZero && fixture.source.layer?.opacity == 0
      }
      guard report.sourceSnapshots == 3, report.sourceSnapshotMarkerHits == 3,
        report.sourceOnly?.ocrComplete == true, report.sourceOnly?.markerHits == 0
      else {
        throw AsideError("Zero-opacity source snapshot or source-only absence control failed")
      }
      for protected in [false, true] {
        fixture.installPresentation(protected: protected)
        guard let layer = fixture.presentation else { throw AsideError("No presentation layer") }
        let counts = try await session.samples(
          stage: protected ? "web-protected" : "web-clear", marker: "ASIDE WEB TEST"
        ) { index in
          try await fixture.setMarker(index)
          let image = try await fixture.snapshot()
          report.sourceSnapshots += 1
          if try CaptureProbeSupport.contains(image, marker: "ASIDE WEB TEST \(701 + index)") {
            report.sourceSnapshotMarkerHits += 1
          }
          layer.sampleBufferRenderer.enqueue(try CaptureProbeSupport.videoSample(image))
          report.sourceOpacityRemainedZero =
            report.sourceOpacityRemainedZero && fixture.source.layer?.opacity == 0
        }
        report.rendererStates.append(
          CaptureProbeSupport.renderer(layer, stage: protected ? "web-protected" : "web-clear"))
        if protected {
          report.protectedPresentation = counts
        } else {
          report.clearPresentation = counts
        }
        fixture.removePresentation()
      }
      report.afterPresentationRemoval = try await session.samples(
        stage: "web-presentation-removed", marker: "ASIDE WEB TEST"
      ) { index in
        try await fixture.setMarker(index)
        report.sourceOpacityRemainedZero =
          report.sourceOpacityRemainedZero && fixture.source.layer?.opacity == 0
      }
    } catch { report.error = error.localizedDescription }
    return report
  }
}

/// Source remains in the responder tree, with a permanently zero-opacity ancestor.
/// The video layer is its sibling. No real UI uses this candidate class.
@MainActor
final class ProtectedWebFixture: NSView {
  let source = NSView()
  let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  private(set) var presentation: AVSampleBufferDisplayLayer?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    source.wantsLayer = true
    source.layer?.opacity = 0  // Before WebKit is attached or any content is loaded.
    addSubview(source)
    source.addSubview(web)
    layoutFixture()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layout() {
    super.layout()
    layoutFixture()
  }
  private func layoutFixture() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    source.frame = bounds
    web.frame = source.bounds
    presentation?.frame = bounds
    CATransaction.commit()
  }
  func installPresentation(protected: Bool) {
    removePresentation()
    let video = AVSampleBufferDisplayLayer()
    video.preventsCapture = protected
    video.videoGravity = .resize
    video.frame = bounds
    layer?.addSublayer(video)
    presentation = video
  }
  func removePresentation() {
    presentation?.removeFromSuperlayer()
    presentation = nil
  }
  func setMarker(_ index: Int) async throws {
    _ = try await web.evaluateJavaScript(
      "document.getElementById('marker').textContent='ASIDE WEB TEST \(701 + index)'")
  }
  func snapshot() async throws -> CGImage {
    let configuration = WKSnapshotConfiguration()
    configuration.rect = web.bounds
    configuration.afterScreenUpdates = true
    let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
      let reply = ProtectedSnapshotReply(continuation)
      web.takeSnapshot(with: configuration) { image, error in
        if let error {
          reply.finish(.failure(error))
        } else if let image {
          reply.finish(.success(image))
        } else {
          reply.finish(.failure(AsideError("Generic web snapshot returned no image")))
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(8))
        reply.finish(
          .failure(AsideError("Generic web snapshot timed out; opacity experiment is inconclusive"))
        )
      }
    }
    guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw AsideError("Generic web snapshot has no bitmap")
    }
    return image
  }
}

@MainActor
private final class ProtectedSnapshotReply {
  private var continuation: CheckedContinuation<NSImage, Error>?
  init(_ continuation: CheckedContinuation<NSImage, Error>) { self.continuation = continuation }
  func finish(_ result: Result<NSImage, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}
