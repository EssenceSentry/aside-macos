import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct CapturedChunk: Sendable {
  var track: AudioTrack
  var url: URL
  var offset: Double
  var speaker: String
}

enum CaptureSource: String, Codable, Sendable {
  case microphone, systemAudio
}
enum CaptureIssueKind: String, Codable, Sendable {
  case writeFailed, sourceStopped, timestampGap, timestampOverlap, timestampUnavailable,
    formatChanged
}
struct CaptureIssue: Codable, Sendable, Equatable {
  var source: CaptureSource
  var kind: CaptureIssueKind
  var offset: Double
  var duration: Double
  var message: String
  var isFailure: Bool { kind == .writeFailed || kind == .sourceStopped }
}

/// Both producers map sample timestamps onto this one monotonic recording origin.
/// ScreenCaptureKit's clock is converted explicitly, including its measured drift.
struct CaptureTimeline: Sendable {
  let hostOrigin: Double
  let timelineOffset: Double
  init(
    timelineOffset: Double, hostOrigin: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds
  ) {
    self.hostOrigin = hostOrigin
    self.timelineOffset = timelineOffset
  }
  func offset(hostSeconds: Double) -> Double? {
    guard hostSeconds.isFinite else { return nil }
    return max(timelineOffset, timelineOffset + hostSeconds - hostOrigin)
  }
  func offset(for time: AVAudioTime) -> Double? {
    guard time.isHostTimeValid else { return nil }
    return offset(hostSeconds: AVAudioTime.seconds(forHostTime: time.hostTime))
  }
  func offset(for time: CMTime, from clock: CMClock?) -> Double? {
    guard time.isValid, time.isNumeric, let clock else { return nil }
    let hostTime = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock())
    guard hostTime.isValid, hostTime.isNumeric else { return nil }
    return offset(hostSeconds: hostTime.seconds)
  }
  var currentOffset: Double {
    offset(hostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds) ?? timelineOffset
  }
}

@MainActor
protocol CaptureService: AnyObject {
  func start(
    directory: URL, systemAudio: Bool, timelineOffset: Double,
    onChunk: @escaping @Sendable (CapturedChunk) -> Void,
    onLevel: @escaping @Sendable (Double, Bool) -> Void,
    onError: @escaping @Sendable (String) -> Void,
    onIssue: (@Sendable (CaptureIssue) -> Void)?
  ) async throws
  func stop() async
}
extension CaptureService {
  func start(
    directory: URL, systemAudio: Bool, timelineOffset: Double,
    onChunk: @escaping @Sendable (CapturedChunk) -> Void,
    onLevel: @escaping @Sendable (Double, Bool) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    try await start(
      directory: directory, systemAudio: systemAudio, timelineOffset: timelineOffset,
      onChunk: onChunk, onLevel: onLevel, onError: onError, onIssue: nil)
  }
}

/// Writes bounded CAF chunks before dispatching transcription. ASR never owns capture buffers.
final class ChunkWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let directory: URL
  private let origin: Date
  private let label: String
  private let prefix: String
  private let timelineOffset: Double
  private let source: CaptureSource
  private let completed: @Sendable (CapturedChunk) -> Void
  private let failed: @Sendable (String) -> Void
  private let onIssue: (@Sendable (CaptureIssue) -> Void)?
  private let writePortion: @Sendable (AVAudioFile, AVAudioPCMBuffer) throws -> Void
  private var file: AVAudioFile?
  private var chunkURL: URL?
  private var offset: Double = 0
  private var frames: AVAudioFramePosition = 0
  private var rate: Double = 48000
  private var enabled = true
  private var nextOffset: Double?
  private var lastFormat: AVAudioFormat?
  private var silentDuration: Double = 0
  private var reportedMissingTime = false
  init(
    directory: URL, origin: Date, label: String, prefix: String, timelineOffset: Double = 0,
    completed: @escaping @Sendable (CapturedChunk) -> Void,
    failed: @escaping @Sendable (String) -> Void,
    source: CaptureSource? = nil,
    onIssue: (@Sendable (CaptureIssue) -> Void)? = nil,
    writePortion: @escaping @Sendable (AVAudioFile, AVAudioPCMBuffer) throws -> Void = {
      try $0.write(from: $1)
    }
  ) {
    self.timelineOffset = timelineOffset
    self.directory = directory
    self.origin = origin
    self.label = label
    self.prefix = prefix
    self.completed = completed
    self.failed = failed
    self.source = source ?? (prefix == "system" ? .systemAudio : .microphone)
    self.onIssue = onIssue
    self.writePortion = writePortion
  }
  var isHealthy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }
  /// Returns false after failure/stop. Producers must suppress healthy meters then.
  /// A nil timestamp is retained for old/synthetic callers. Live callers supply an
  /// explicitly approximate host-arrival fallback if the source timestamp is unavailable.
  @discardableResult
  func write(
    _ buffer: AVAudioPCMBuffer, at sourceOffset: Double? = nil, fallbackOffset: Double? = nil
  ) -> Bool {
    var chunks: [CapturedChunk] = []
    var issues: [CaptureIssue] = []
    lock.lock()
    guard enabled else {
      lock.unlock()
      return false
    }
    let supplied = sourceOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
    let fallback = fallbackOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
    let start = supplied ?? fallback
    if supplied == nil, let fallback, !reportedMissingTime {
      reportedMissingTime = true
      issues.append(
        CaptureIssue(
          source: source, kind: .timestampUnavailable, offset: fallback, duration: 0,
          message:
            "\(label) source timestamps are unavailable. Host arrival time is approximate; alignment cannot be verified."
        ))
    }
    var consumed = 0
    do {
      guard buffer.format.sampleRate > 0 else { throw AsideError("Invalid audio sample rate") }
      if buffer.frameLength > 0 {
        let expected = file == nil ? nextOffset : offset + Double(frames) / rate
        if let start, let expected, abs(start - expected) > max(0.02, 2 / buffer.format.sampleRate)
        {
          if let chunk = finishLocked() { chunks.append(chunk) }
          let gap = start - expected
          issues.append(
            CaptureIssue(
              source: source, kind: gap > 0 ? .timestampGap : .timestampOverlap,
              offset: min(start, expected), duration: abs(gap),
              message: gap > 0
                ? "\(label) capture has a \(String(format: "%.3f", gap))-second gap. No speech was recorded in that interval."
                : "\(label) source timestamps moved backward by \(String(format: "%.3f", -gap)) seconds. Audio was retained with overlapping source times."
            ))
          nextOffset = start
        } else if file == nil, let start {
          nextOffset = start
        }
        if let lastFormat, !lastFormat.isEqual(buffer.format) {
          if let chunk = finishLocked() { chunks.append(chunk) }
          if let start { nextOffset = start }
          issues.append(
            CaptureIssue(
              source: source, kind: .formatChanged, offset: start ?? nextOffset ?? timelineOffset,
              duration: 0,
              message: "\(label) audio format changed. A new source-timed chunk was started."))
        }
        lastFormat = buffer.format
      }
      while consumed < Int(buffer.frameLength) {
        if file == nil {
          offset = nextOffset ?? start ?? timelineOffset + max(0, Date().timeIntervalSince(origin))
          rate = buffer.format.sampleRate
          let name = String(format: "%@-%012.3f-%@.caf", prefix, offset, newID())
          chunkURL = directory.appendingPathComponent(name)
          file = try AVAudioFile(
            forWriting: chunkURL!, settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: chunkURL!.path)
          frames = 0
          silentDuration = 0
        }
        let remaining = max(1, Int(rate * 6) - Int(frames))
        let count = min(remaining, Int(buffer.frameLength) - consumed)
        guard
          let portion = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))
        else { throw AsideError("Audio buffer allocation failed") }
        portion.frameLength = AVAudioFrameCount(count)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(portion.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
          let bytesPerFrame = Int(from.mDataByteSize) / Int(buffer.frameLength)
          if let a = from.mData, let b = to.mData {
            memcpy(b, a.advanced(by: consumed * bytesPerFrame), count * bytesPerFrame)
          }
        }
        if let file { try writePortion(file, portion) }
        frames += AVAudioFramePosition(count)
        consumed += count
        var sum: Float = 0
        if let samples = portion.floatChannelData?[0] {
          for i in 0..<count { sum += samples[i] * samples[i] }
          let rms = sqrt(sum / Float(max(1, count)))
          silentDuration = rms < 0.003 ? silentDuration + Double(count) / rate : 0
        }
        let duration = Double(frames) / rate
        if duration >= 6 || (duration >= 3 && silentDuration >= 0.45) {
          if let chunk = finishLocked() { chunks.append(chunk) }
        }
      }
    } catch {
      enabled = false
      // A writer can advance before throwing. Preserve every frame it actually committed.
      if let file {
        let committed = max(frames, file.framePosition)
        consumed = min(Int(buffer.frameLength), consumed + Int(committed - frames))
        frames = committed
      }
      let failureOffset =
        file == nil ? (nextOffset ?? start ?? timelineOffset) : offset + Double(frames) / rate
      if let chunk = finishLocked() { chunks.append(chunk) }
      issues.append(
        CaptureIssue(
          source: source, kind: .writeFailed, offset: failureOffset,
          duration: Double(Int(buffer.frameLength) - consumed) / max(1, buffer.format.sampleRate),
          message: "\(label) recording write failed: \(error.localizedDescription)"))
    }
    let healthy = enabled
    lock.unlock()
    // Never invoke clients while holding the writer lock: issue handlers may query health/stop.
    chunks.forEach(completed)
    for issue in issues {
      onIssue?(issue)
      if issue.isFailure { failed(issue.message) }
    }
    return healthy
  }
  func fail(kind: CaptureIssueKind = .sourceStopped, offset failureOffset: Double, message: String)
  {
    lock.lock()
    guard enabled else {
      lock.unlock()
      return
    }
    enabled = false
    let chunk = finishLocked()
    lock.unlock()
    if let chunk { completed(chunk) }
    let issue = CaptureIssue(
      source: source, kind: kind, offset: failureOffset, duration: 0, message: message)
    onIssue?(issue)
    failed(message)
  }
  func finish() {
    lock.lock()
    enabled = false
    let chunk = finishLocked()
    lock.unlock()
    if let chunk { completed(chunk) }
  }
  private func finishLocked() -> CapturedChunk? {
    guard let url = chunkURL else { return nil }
    file = nil
    chunkURL = nil
    let duration = Double(frames) / rate
    frames = 0
    nextOffset = offset + duration
    guard duration > 0 else { return nil }
    let track = AudioTrack(
      id: url.deletingPathExtension().lastPathComponent, label: label,
      filename: url.lastPathComponent, duration: duration)
    return CapturedChunk(track: track, url: url, offset: offset, speaker: label)
  }
  static func offset(for filename: String) -> Double {
    Double(filename.split(separator: "-").dropFirst().first ?? "0") ?? 0
  }
}

@MainActor
final class AudioCapture: NSObject, SCStreamDelegate, CaptureService {
  private var activeToken: String?
  private var engine: AVAudioEngine?
  private var stream: SCStream?
  private var micWriter: ChunkWriter?
  private var systemWriter: ChunkWriter?
  private var systemSink: SystemAudioSink?
  private var configurationObserver: NSObjectProtocol?
  private let systemQueue = DispatchQueue(label: "aside.system-audio")
  private var issueHandler: (@Sendable (CaptureIssue) -> Void)?
  private var timeline: CaptureTimeline?
  private var levelHandler: (@Sendable (Double, Bool) -> Void)?
  var sourceHealth: [CaptureSource: Bool] {
    [.microphone: micWriter?.isHealthy == true, .systemAudio: systemWriter?.isHealthy == true]
  }
  func start(
    directory: URL, systemAudio: Bool, timelineOffset: Double,
    onChunk: @escaping @Sendable (CapturedChunk) -> Void,
    onLevel: @escaping @Sendable (Double, Bool) -> Void,
    onError: @escaping @Sendable (String) -> Void,
    onIssue: (@Sendable (CaptureIssue) -> Void)? = nil
  ) async throws {
    guard activeToken == nil, engine == nil else { throw AsideError("Already recording") }
    let token = newID()
    activeToken = token
    let permitted = await AVCaptureDevice.requestAccess(for: .audio)
    guard activeToken == token else { throw CancellationError() }
    guard permitted else {
      activeToken = nil
      throw AsideError(
        "Microphone permission is required. Enable Aside in System Settings → Privacy & Security → Microphone."
      )
    }
    let timeline = CaptureTimeline(timelineOffset: timelineOffset)
    self.timeline = timeline
    levelHandler = onLevel
    let deliver: @Sendable (CaptureIssue) -> Void = { [weak self] issue in
      if issue.isFailure { onLevel(0, issue.source == .systemAudio) }
      if let onIssue { onIssue(issue) } else if issue.isFailure { onError(issue.message) }
      if issue.isFailure {
        Task { @MainActor [weak self] in await self?.stopFailedSource(issue.source, token: token) }
      }
    }
    issueHandler = deliver
    let writer = ChunkWriter(
      directory: directory, origin: Date(), label: "Microphone", prefix: "mic",
      timelineOffset: timelineOffset, completed: onChunk, failed: { _ in }, source: .microphone,
      onIssue: deliver)
    micWriter = writer
    let audioEngine = AVAudioEngine()
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      activeToken = nil
      micWriter = nil
      throw AsideError("No usable microphone input is available")
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
      let healthy = writer.write(
        buffer, at: timeline.offset(for: time), fallbackOffset: timeline.currentOffset)
      onLevel(healthy ? Self.level(buffer) : 0, false)
    }
    do {
      try audioEngine.start()
      engine = audioEngine
      configurationObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
      ) { _ in
        writer.fail(
          offset: timeline.currentOffset,
          message:
            "Microphone capture stopped after an audio-device configuration change. Resume recording to reconnect it."
        )
      }
    } catch {
      input.removeTap(onBus: 0)
      writer.finish()
      micWriter = nil
      activeToken = nil
      throw error
    }
    if systemAudio {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
        guard activeToken == token else { throw CancellationError() }
        guard let display = content.displays.first else {
          throw AsideError("No display is available for system audio capture")
        }
        let filter = SCContentFilter(
          display: display,
          excludingApplications: content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
          },
          exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let systemWriter = ChunkWriter(
          directory: directory, origin: Date(), label: "System audio", prefix: "system",
          timelineOffset: timelineOffset, completed: onChunk, failed: { _ in },
          source: .systemAudio,
          onIssue: deliver)
        self.systemWriter = systemWriter
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        let sink = SystemAudioSink(writer: systemWriter, timeline: timeline, level: onLevel)
        systemSink = sink
        try capture.addStreamOutput(sink, type: .audio, sampleHandlerQueue: systemQueue)
        stream = capture
        try await capture.startCapture()
        guard activeToken == token else {
          try? await capture.stopCapture()
          throw CancellationError()
        }
      } catch {
        guard activeToken == token else { throw CancellationError() }
        systemWriter?.finish()
        systemWriter = nil
        deliver(
          CaptureIssue(
            source: .systemAudio, kind: .sourceStopped, offset: timeline.currentOffset, duration: 0,
            message:
              "System audio unavailable: \(error.localizedDescription). Microphone recording continues. Check Screen & System Audio Recording permission for Aside."
          ))
      }
    }
  }
  private func stopFailedSource(_ source: CaptureSource, token: String) async {
    guard activeToken == token else { return }
    if source == .microphone {
      if let configurationObserver {
        NotificationCenter.default.removeObserver(configurationObserver)
      }
      configurationObserver = nil
      engine?.inputNode.removeTap(onBus: 0)
      engine?.stop()
      engine = nil
    } else if let capture = stream {
      try? await capture.stopCapture()
      if stream === capture {
        stream = nil
        systemSink = nil
      }
    }
  }
  func stop() async {
    activeToken = nil
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    if let stream { try? await stream.stopCapture() }
    stream = nil
    await withCheckedContinuation { continuation in systemQueue.async { continuation.resume() } }
    micWriter?.finish()
    systemWriter?.finish()
    micWriter = nil
    systemWriter = nil
    systemSink = nil
    levelHandler?(0, false)
    levelHandler?(0, true)
    issueHandler = nil
    timeline = nil
  }
  nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Double {
    guard let values = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) { sum += values[i] * values[i] }
    return min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 5)
  }
  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor [weak self] in
      guard let self, self.activeToken != nil, self.stream === stream else { return }
      self.systemWriter?.fail(
        offset: self.timeline?.currentOffset ?? 0,
        message:
          "System capture stopped: \(error.localizedDescription). Microphone recording continues.")
    }
  }
}

/// One immutable sink per stream; all writes complete synchronously on the capture queue.
private final class SystemAudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
  let writer: ChunkWriter
  let timeline: CaptureTimeline
  let levelHandler: @Sendable (Double, Bool) -> Void
  init(
    writer: ChunkWriter, timeline: CaptureTimeline,
    level: @escaping @Sendable (Double, Bool) -> Void
  ) {
    self.writer = writer
    self.timeline = timeline
    self.levelHandler = level
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio else { return }
    guard sampleBuffer.isValid, let desc = sampleBuffer.formatDescription else {
      writer.fail(
        offset: timeline.currentOffset, message: "System audio delivered an invalid capture buffer."
      )
      levelHandler(0, true)
      return
    }
    let format = AVAudioFormat(cmAudioFormatDescription: desc)
    let size =
      MemoryLayout<AudioBufferList>.size + Int(format.channelCount) * MemoryLayout<AudioBuffer>.size
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var retained: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retained)
    guard status == noErr, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list)
    else {
      writer.fail(
        offset: timeline.currentOffset,
        message: "System audio capture buffer could not be read (\(status)).")
      levelHandler(0, true)
      return
    }
    let sourceOffset = timeline.offset(
      for: sampleBuffer.presentationTimeStamp, from: stream.synchronizationClock)
    let healthy = writer.write(buffer, at: sourceOffset, fallbackOffset: timeline.currentOffset)
    levelHandler(healthy ? AudioCapture.level(buffer) : 0, true)
  }
}
