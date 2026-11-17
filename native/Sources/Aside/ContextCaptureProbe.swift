import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Vision

struct CaptureProbeSamples: Codable, Sendable {
  var stage: String
  var samples: Int = 0
  var markerHits: Int = 0
  var changingMarkerHits: Int = 0
  var excludedReferenceComparisons: [CaptureProbeROIComparison]? = nil
  var ocrCompletedSamples: Int? = nil
  var ocrErrors: [CaptureProbeOCRError]? = nil
  var ocrComplete: Bool {
    samples > 0 && ocrCompletedSamples == samples && (ocrErrors ?? []).isEmpty
  }
  var targetWindowVisibleSamples: Int? = nil
  var targetWindowUnoccludedSamples: Int? = nil
}
struct CaptureProbeRenderer: Codable, Sendable {
  var stage: String
  var status: Int
  var readyForDisplay: Bool?
  var error: String?
  var valid: Bool {
    status == AVQueuedSampleBufferRenderingStatus.rendering.rawValue && readyForDisplay != false
      && error == nil
  }
}
struct ContextCaptureReport: Codable, Sendable {
  var createdAt: String
  var system: String
  // Nil means OCR did not establish visibility; it must never be interpreted as hidden.
  var baselineVisible: Bool?
  var exclusionFlagVisible: Bool?
  var capturerExclusionVisible: Bool?
  var videoBaselineVisible: Bool? = nil
  var protectedVideoVisible: Bool? = nil
  var videoError: String? = nil
  var sampleCounts: [CaptureProbeSamples]? = nil
  var rendererStates: [CaptureProbeRenderer]? = nil
  var webPrototype: ProtectedWebProbeReport? = nil
  var protectedLocalDisplayVisuallyConfirmed: Bool = false
  var windowLocalDisplayVisuallyConfirmed: Bool = false
  var windowPixelAssessment: String? = nil
  var windowMarkerAssessment: String? = nil
  var ocrErrorCount: Int? = nil
  mutating func assessWindowCapture() {
    let stages = sampleCounts ?? []
    ocrErrorCount = stages.reduce(0) { $0 + ($1.ocrErrors?.count ?? 0) }
    windowPixelAssessment = "inconclusive"
    windowMarkerAssessment = "inconclusive"
    let noneNames = ["none-live-transition", "none-filter-refresh", "none-new-stream"]
    let excluded = stages.filter { noneNames.contains($0.stage) }
    guard let normal = stages.first(where: { $0.stage == "normal-live" }),
      let restored = stages.first(where: { $0.stage == "normal-restored" }),
      let control = stages.first(where: { $0.stage == "explicit-exclude" }), excluded.count == 3,
      ([normal, restored, control] + excluded).allSatisfy({ $0.samples == 3 })
    else { return }
    let all = [normal, restored, control] + excluded
    let grids = all.map { Self.completePixelGrid($0) }
    if grids.allSatisfy({ $0 != nil }) {
      let normalContrast = (grids[0]! + grids[1]!).allSatisfy {
        $0.changedPixelFraction > 0 && $0.meanAbsoluteRGBDifference > 0
      }
      let controlMatches = grids[2]!.allSatisfy(Self.matchesReference)
      if normalContrast, controlMatches {
        let noneMatches = grids.dropFirst(3).flatMap { $0! }.allSatisfy(Self.matchesReference)
        windowPixelAssessment =
          noneMatches ? "sampled-regions-match-exclusion" : "sampled-regions-differ-from-exclusion"
      }
    }
    if all.allSatisfy(\.ocrComplete), normal.markerHits == 3, normal.changingMarkerHits == 3,
      restored.markerHits == 3, restored.changingMarkerHits == 3, control.markerHits == 0
    {
      windowMarkerAssessment =
        excluded.contains { $0.markerHits > 0 }
        ? "marker-visible" : "marker-absent-in-successful-OCR"
    }
  }
  private static func completePixelGrid(_ stage: CaptureProbeSamples)
    -> [CaptureProbeROIComparison]?
  {
    guard let rows = stage.excludedReferenceComparisons, rows.count == 6 else { return nil }
    for region in ["window", "native-marker"] {
      for index in 0..<3 {
        guard
          rows.filter({ $0.region == region && $0.sample == index && $0.sampledPixelCount == 4096 })
            .count == 1
        else { return nil }
      }
    }
    return rows
  }
  private static func matchesReference(_ row: CaptureProbeROIComparison) -> Bool {
    row.meanAbsoluteRGBDifference == 0 && row.changedPixelFraction == 0
  }
  var explanation: String {
    let pixelDetail: String
    switch windowPixelAssessment {
    case "sampled-regions-match-exclusion":
      pixelDetail =
        "Pixel comparison: the sampled window regions matched the explicitly excluded background in all nine exclusion-flag frames. Both ordinary-window controls differed. This supports omission of those sampled regions for this local capturer."
    case "sampled-regions-differ-from-exclusion":
      pixelDetail =
        "Pixel comparison: some sampled window pixels differed from the excluded background with the exclusion flag enabled. An empty window, visible content, or background movement remains possible."
    default:
      pixelDetail =
        "Pixel comparison: INCONCLUSIVE; complete independent pixel controls did not pass."
    }
    let markerDetail: String
    switch windowMarkerAssessment {
    case "marker-visible":
      markerDetail = "Marker recognition: the marker appeared with the exclusion flag enabled."
    case "marker-absent-in-successful-OCR":
      markerDetail =
        "Marker recognition: all requests and ordinary controls passed; the marker was absent in the exclusion-flag frames."
    default:
      markerDetail =
        "Marker recognition: INCONCLUSIVE. Failed OCR is never evidence of a hidden marker."
    }
    let rows = (sampleCounts ?? []).map { stage in
      stage.ocrComplete
        ? "\(stage.stage): \(stage.markerHits)/\(stage.samples) marker hits"
        : "\(stage.stage): \(stage.samples) captured, OCR \(stage.ocrCompletedSamples ?? 0)/\(stage.samples) completed (inconclusive)"
    }.joined(separator: "\n")
    return "Full-display capture diagnostic\n\n" + pixelDetail + "\n\n" + markerDetail
      + "\n\n" + rows
      + (videoError.map { "\n\nProbe stopped: " + $0 } ?? "")
      + (webPrototype.map { "\n\n" + $0.summary } ?? "")
      + "\n\nEach ROI uses 64×64 sample pixels; exterior shadows and transition frames are unmeasured. This does not establish Slack, Zoom, or other sharing modes. No screenshot, video, or recognized screen text was saved."
  }
}

/// Only generic fixtures are displayed during this explicit test. Original content is detached.
@MainActor
struct ContextCaptureProbe {
  static func run(panel: NSPanel, includeVideoExperiments: Bool = false) async throws
    -> ContextCaptureReport
  {
    guard let original = panel.contentView else { throw AsideError("Open floating help first") }
    let previousSharing = panel.sharingType
    let fixture = NSView(frame: original.bounds)
    fixture.wantsLayer = true
    fixture.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    panel.contentView = fixture
    defer {
      panel.sharingType = previousSharing
      panel.contentView = original
    }
    let marker = NSTextField(labelWithString: "ASIDE CAPTURE TEST 701")
    marker.font = .boldSystemFont(ofSize: 23)
    marker.textColor = .labelColor
    marker.backgroundColor = .windowBackgroundColor
    marker.drawsBackground = true
    marker.alignment = .center
    marker.frame = NSRect(
      x: 8, y: fixture.bounds.midY - 45, width: fixture.bounds.width - 16, height: 90)
    marker.autoresizingMask = [.width, .minYMargin, .maxYMargin]
    fixture.addSubview(marker)
    panel.sharingType = .readOnly
    panel.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(350))
    let available = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let identifier =
      panel.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
      as? CGDirectDisplayID
    guard
      let display = available.displays.first(where: { $0.displayID == identifier })
        ?? available.displays.first,
      let own = available.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) })
    else { throw AsideError("The generic test window was not available") }
    let all = SCContentFilter(display: display, excludingWindows: [])
    let excluded = SCContentFilter(display: display, excludingWindows: [own])
    let session = try CaptureProbeSession(
      filter: all, display: display, screen: panel.screen, targetWindow: panel)
    try await session.start()
    var report = ContextCaptureReport(
      createdAt: timestamp(), system: ProcessInfo.processInfo.operatingSystemVersionString,
      baselineVisible: nil, exclusionFlagVisible: nil, capturerExclusionVisible: nil,
      sampleCounts: [], rendererStates: [])
    do {
      // Capture a transient explicit-exclusion reference before any comparisons.
      // The standalone harness puts a generic checkerboard behind this window.
      try await session.stream.updateContentFilter(excluded)
      if let screen = panel.screen {
        let markerInWindow = fixture.convert(marker.frame, to: nil)
        try await session.captureExcludedReference(
          regions: [
            "window": panel.frame.insetBy(dx: 6, dy: 6),
            "native-marker": panel.convertToScreen(markerInWindow),
          ],
          screenFrame: screen.frame)
      }
      try await session.stream.updateContentFilter(all)
      let baseline = try await session.samples(stage: "normal-live", marker: "ASIDE CAPTURE TEST") {
        index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(baseline)
      report.baselineVisible = baseline.ocrComplete ? baseline.markerHits > 0 : nil
      panel.sharingType = .none
      let live = try await session.samples(
        stage: "none-live-transition", marker: "ASIDE CAPTURE TEST"
      ) { index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(live)
      // Reuse the same live stream, then explicitly refresh its filter.
      try await session.stream.updateContentFilter(
        SCContentFilter(display: display, excludingWindows: []))
      let refreshed = try await session.samples(
        stage: "none-filter-refresh", marker: "ASIDE CAPTURE TEST"
      ) { index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(refreshed)
      try await session.restart(filter: all)
      let fresh = try await session.samples(stage: "none-new-stream", marker: "ASIDE CAPTURE TEST")
      { index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(fresh)
      report.exclusionFlagVisible =
        [live, refreshed, fresh].allSatisfy(\.ocrComplete)
        ? [live, refreshed, fresh].contains { $0.markerHits > 0 } : nil
      panel.sharingType = .readOnly
      try await session.stream.updateContentFilter(excluded)
      let control = try await session.samples(
        stage: "explicit-exclude", marker: "ASIDE CAPTURE TEST"
      ) { index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(control)
      report.capturerExclusionVisible = control.ocrComplete ? control.markerHits > 0 : nil
      panel.sharingType = .readOnly
      try await session.stream.updateContentFilter(all)
      let restored = try await session.samples(
        stage: "normal-restored", marker: "ASIDE CAPTURE TEST"
      ) { index in
        marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
      }
      report.sampleCounts?.append(restored)
      guard includeVideoExperiments else {
        await session.stop()
        report.assessWindowCapture()
        return report
      }
      marker.isHidden = true
      for protected in [false, true] {
        let name = protected ? "video-protected" : "video-normal"
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = marker.frame
        layer.videoGravity = .resize
        // Set before adding or enqueuing; never recycle a clear layer.
        layer.preventsCapture = protected
        fixture.layer?.addSublayer(layer)
        defer { layer.removeFromSuperlayer() }
        let counts = try await session.samples(stage: name, marker: "ASIDE CAPTURE TEST") { index in
          marker.stringValue = "ASIDE CAPTURE TEST \(701 + index)"
          let image = try CaptureProbeSupport.markerImage(
            marker.stringValue, size: marker.bounds.size)
          layer.sampleBufferRenderer.enqueue(try CaptureProbeSupport.videoSample(image))
        }
        let renderer = CaptureProbeSupport.renderer(layer, stage: name)
        report.rendererStates?.append(renderer)
        report.sampleCounts?.append(counts)
        if protected {
          report.protectedVideoVisible =
            renderer.valid && counts.ocrComplete ? counts.markerHits > 0 : nil
        } else {
          report.videoBaselineVisible =
            counts.ocrComplete
            ? renderer.valid && counts.markerHits == 3 && counts.changingMarkerHits == 3 : nil
        }
      }
      if report.baselineVisible == true, report.capturerExclusionVisible == false,
        report.videoBaselineVisible == true, report.protectedVideoVisible == false,
        report.rendererStates?.allSatisfy(\.valid) == true
      {
        report.webPrototype = try await ProtectedWebProbe.run(panel: panel, session: session)
      }
      await session.stop()
    } catch {
      await session.stop()
      report.videoError = error.localizedDescription
    }
    report.assessWindowCapture()
    return report
  }
}

@MainActor
enum CaptureProbeSupport {
  static func renderer(_ layer: AVSampleBufferDisplayLayer, stage: String) -> CaptureProbeRenderer {
    var ready: Bool?
    if #available(macOS 14.4, *) { ready = layer.isReadyForDisplay }
    return CaptureProbeRenderer(
      stage: stage, status: layer.sampleBufferRenderer.status.rawValue,
      readyForDisplay: ready, error: layer.sampleBufferRenderer.error?.localizedDescription)
  }
  static func contains(_ image: CGImage, marker: String) throws -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    // Only the boolean escapes; recognized text and image remain transient.
    return (request.results ?? []).contains {
      $0.topCandidates(1).first?.string.uppercased().contains(marker.uppercased()) == true
    }
  }
  static func markerImage(_ text: String, size: NSSize) throws -> CGImage {
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor.windowBackgroundColor.setFill()
      rect.fill()
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      (text as NSString).draw(
        in: rect.insetBy(dx: 4, dy: 15),
        withAttributes: [
          .font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ])
      return true
    }
    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw AsideError("Could not rasterize the generic marker")
    }
    return bitmap
  }
  static func videoSample(_ image: CGImage) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, image.width, image.height,
        kCVPixelFormatType_32BGRA, attributes, &pixel) == kCVReturnSuccess, let pixel
    else { throw AsideError("Could not prepare the local video-layer experiment") }
    CVPixelBufferLockBaseAddress(pixel, [])
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixel), width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else {
      CVPixelBufferUnlockBaseAddress(pixel, [])
      throw AsideError("Could not draw the video test")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
      let format
    else { throw AsideError("Could not describe the video test frame") }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample
    else { throw AsideError("Could not create the video test frame") }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
      as? [NSMutableDictionary]
    {
      attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    return sample
  }

}

/// A generic heartbeat window forces fresh complete display frames even if the target is excluded.
/// It is never excluded along with the target and contains no application/user data.
@MainActor
final class CaptureProbeSession {
  private(set) var stream: SCStream
  private var receiver = CaptureProbeFrame()
  private let display: SCDisplay
  private let heartbeat: NSPanel
  private let pulse = NSTextField(labelWithString: "Capture control 0")
  private var sequence = 0
  private var references: [String: (rect: CGRect, bytes: [UInt8])] = [:]
  private weak var targetWindow: NSWindow?
  init(
    filter: SCContentFilter, display: SCDisplay, screen: NSScreen?, targetWindow: NSWindow? = nil
  ) throws {
    self.display = display
    self.targetWindow = targetWindow
    let screenFrame = screen?.visibleFrame ?? NSScreen.main!.visibleFrame
    heartbeat = NSPanel(
      contentRect: NSRect(
        x: screenFrame.minX + 20, y: screenFrame.minY + 20, width: 220, height: 48),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    heartbeat.level = .floating
    heartbeat.isReleasedWhenClosed = false
    heartbeat.hidesOnDeactivate = false
    heartbeat.sharingType = .readOnly
    pulse.frame = NSRect(x: 8, y: 10, width: 204, height: 28)
    pulse.font = .systemFont(ofSize: 18)
    heartbeat.contentView?.addSubview(pulse)
    stream = SCStream(filter: filter, configuration: Self.configuration(display), delegate: nil)
    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
  }
  private static func configuration(_ display: SCDisplay) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    configuration.showsCursor = false
    configuration.capturesAudio = false
    return configuration
  }
  func start() async throws {
    heartbeat.orderFrontRegardless()
    do { try await stream.startCapture() } catch {
      heartbeat.orderOut(nil)
      throw error
    }
  }
  func stop() async {
    try? await stream.stopCapture()
    heartbeat.orderOut(nil)
  }
  func restart(filter: SCContentFilter) async throws {
    try await stream.stopCapture()
    receiver = CaptureProbeFrame()
    stream = SCStream(filter: filter, configuration: Self.configuration(display), delegate: nil)
    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
    try await stream.startCapture()
  }
  func captureExcludedReference(regions: [String: CGRect], screenFrame: CGRect) async throws {
    try await Task.sleep(for: .milliseconds(500))
    receiver.reset()
    sequence += 1
    pulse.stringValue = "Capture control \(sequence)"
    heartbeat.displayIfNeeded()
    let image = try await receiver.image()
    for (name, global) in regions {
      let scaleX = CGFloat(image.width) / screenFrame.width
      let scaleY = CGFloat(image.height) / screenFrame.height
      let rect = CGRect(
        x: (global.minX - screenFrame.minX) * scaleX,
        y: (screenFrame.maxY - global.maxY) * scaleY,
        width: global.width * scaleX, height: global.height * scaleY
      ).integral
      references[name] = (rect, try CaptureProbePixels.bytes(image, rect: rect))
    }
  }
  func samples(stage: String, marker: String, prepare: (Int) async throws -> Void) async throws
    -> CaptureProbeSamples
  {
    var result = CaptureProbeSamples(stage: stage, ocrCompletedSamples: 0)
    for index in 0..<3 {
      try await prepare(index)
      try await Task.sleep(for: .milliseconds(500))
      receiver.reset()
      sequence += 1
      pulse.stringValue = "Capture control \(sequence)"
      heartbeat.displayIfNeeded()
      let image = try await receiver.image()
      result.samples += 1
      if let targetWindow {
        result.targetWindowVisibleSamples =
          (result.targetWindowVisibleSamples ?? 0) + (targetWindow.isVisible ? 1 : 0)
        result.targetWindowUnoccludedSamples =
          (result.targetWindowUnoccludedSamples ?? 0)
          + (targetWindow.occlusionState.contains(.visible) ? 1 : 0)
      }
      for name in references.keys.sorted() {
        guard let reference = references[name] else { continue }
        let bytes = try CaptureProbePixels.bytes(image, rect: reference.rect)
        if result.excludedReferenceComparisons == nil { result.excludedReferenceComparisons = [] }
        result.excludedReferenceComparisons?.append(
          CaptureProbePixels.compare(bytes, to: reference.bytes, region: name, sample: index))
      }
      let recognition = CaptureProbeOCR.inspect(
        image, marker: marker, suffix: 701 + index, sample: index)
      if let error = recognition.error {
        if result.ocrErrors == nil { result.ocrErrors = [] }
        result.ocrErrors?.append(error)
      } else if let visible = recognition.markerVisible,
        let numbered = recognition.numberedMarkerVisible
      {
        result.ocrCompletedSamples = (result.ocrCompletedSamples ?? 0) + 1
        if visible { result.markerHits += 1 }
        if numbered { result.changingMarkerHits += 1 }
      }
    }
    return result
  }
}

private final class CaptureProbeFrame: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue = DispatchQueue(label: "aside.generic-capture-probe")
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CGImage, Error>?
  private var result: Result<CGImage, Error>?
  private var generation = 0
  func reset() {
    // Drain preceding frame callbacks, preventing an old completed frame from crossing a stage boundary.
    queue.sync {
      lock.lock()
      result = nil
      generation += 1
      lock.unlock()
    }
  }
  func image() async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
        return
      }
      self.continuation = continuation
      let expected = generation
      lock.unlock()
      queue.asyncAfter(deadline: .now() + 8) { [self] in
        finish(
          .failure(AsideError("No complete screen frame arrived; this stage is inconclusive")),
          generation: expected)
      }
    }
  }
  private func finish(_ value: Result<CGImage, Error>, generation expected: Int? = nil) {
    lock.lock()
    guard result == nil, expected == nil || expected == generation else {
      lock.unlock()
      return
    }
    result = value
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume(with: value)
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue
    else { return }
    lock.lock()
    let needed = result == nil
    lock.unlock()
    guard needed else { return }
    let image = CIImage(cvPixelBuffer: buffer)
    if let image = CIContext().createCGImage(image, from: image.extent) { finish(.success(image)) }
  }
}
