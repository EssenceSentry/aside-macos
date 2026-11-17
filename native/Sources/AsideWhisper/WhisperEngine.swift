import Foundation
import WhisperKit

public struct WhisperWord: Codable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}
public struct WhisperPassage: Codable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  public var words: [WhisperWord]? = nil
  public init(text: String, start: Double, end: Double, words: [WhisperWord]? = nil) {
    self.text = text
    self.start = start
    self.end = end
    self.words = words
  }
}
public struct WhisperAudioWindow: Codable, Sendable, Equatable {
  public var coreStart: Double
  public var coreEnd: Double
  public var audioStart: Double
  public var audioEnd: Double
  public init(coreStart: Double, coreEnd: Double, audioStart: Double, audioEnd: Double) {
    self.coreStart = coreStart
    self.coreEnd = coreEnd
    self.audioStart = audioStart
    self.audioEnd = audioEnd
  }
}

public struct WhisperWindowResult: Codable, Sendable {
  public var window: WhisperAudioWindow
  /// Full direct-audio alternatives, including the overlapping context.
  public var alternatives: [WhisperPassage]
  public var retained: [WhisperPassage]
  public var timingIssues: [RecognitionTimingIssue]
}

public struct WhisperWindowRecognition: Codable, Sendable {
  public var passages: [WhisperPassage]
  public var windows: [WhisperWindowResult]
  public var timingIssues: [RecognitionTimingIssue]
  public var timingComplete: Bool { timingIssues.isEmpty }
}

public actor WhisperEngine {
  private let directory: URL
  private var pipeline: WhisperKit?
  private var loading: Task<Void, Error>?
  public init(root: URL) { directory = root.appendingPathComponent("models/whisper-turbo") }
  private func savedFolder() -> URL? {
    guard
      let relative = try? String(
        contentsOf: directory.appendingPathComponent("ready-path"), encoding: .utf8),
      !relative.contains(".."), !relative.hasPrefix("/")
    else { return nil }
    let folder = directory.appendingPathComponent(relative)
    guard
      ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy({
        FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
      })
    else { return nil }
    return folder
  }
  public func downloaded() -> Bool { savedFolder() != nil }

  /// Called only after the owning speech actor detaches this idle generation.
  /// Subsequent work belongs to a fresh engine, not this retired instance.
  public func releaseRetiredResources() async {
    let retired = pipeline
    pipeline = nil
    await retired?.unloadModels()
  }
  public func prepare(download: Bool) async throws {
    if pipeline != nil { return }
    if let loading {
      try await loading.value
      return
    }
    let task = Task { try await self.load(download: download) }
    loading = task
    defer { loading = nil }
    try await task.value
  }
  private func load(download: Bool) async throws {
    let folder = savedFolder()
    guard download || folder != nil else {
      throw WhisperSetupError.missingModel
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let config = WhisperKitConfig(
      model: "large-v3-v20240930_turbo", downloadBase: directory,
      modelFolder: folder?.path, tokenizerFolder: directory,
      // Match the validated local ASR path without a Metal mel dependency.
      computeOptions: ModelComputeOptions(
        melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine),
      verbose: false, prewarm: false, load: true, download: download && folder == nil)
    let loaded = try await WhisperKit(config)
    guard let modelFolder = loaded.modelFolder, modelFolder.path.hasPrefix(directory.path + "/")
    else { throw WhisperSetupError.missingModel }
    let relative = String(modelFolder.path.dropFirst(directory.path.count + 1))
    let marker = directory.appendingPathComponent("ready-path")
    if (try? String(contentsOf: marker, encoding: .utf8)) != relative {
      try relative.write(to: marker, atomically: true, encoding: .utf8)
    }
    pipeline = loaded
  }
  public func transcribe(
    _ samples: [Float], language: String? = nil, terms: [String] = [], vad: Bool = false,
    words: Bool = false,
    firstTokenLogProbThreshold: Float? = nil, temperatureFallbackCount: Int = 0,
    detectLanguage: Bool? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> [WhisperPassage] {
    try await prepare(download: false)
    guard let pipeline else { throw WhisperSetupError.missingModel }
    let prompt =
      terms.isEmpty
      ? nil
      : pipeline.tokenizer?.encode(text: "Terminology: " + terms.prefix(32).joined(separator: ", "))
    let options = Self.decodingOptions(
      language: language, words: words, promptTokens: prompt, vad: vad,
      firstTokenLogProbThreshold: firstTokenLogProbThreshold,
      temperatureFallbackCount: temperatureFallbackCount, detectLanguage: detectLanguage)
    let results = try await pipeline.transcribe(
      audioArray: samples, decodeOptions: options,
      segmentCallback: { segments in
        let end = segments.map { Double($0.end) }.max() ?? 0
        progress?(min(0.99, end / max(1, Double(samples.count) / 16000)))
      })
    return results.flatMap(\.segments).map {
      WhisperPassage(
        text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: Double($0.start),
        end: Double($0.end),
        words: $0.words?.map {
          WhisperWord(text: $0.word, start: Double($0.start), end: Double($0.end))
        })
    }.filter { !$0.text.isEmpty }
  }

  /// Experimental acoustic alternative. Each original-audio window is decoded
  /// independently; it never derives missing words from surrounding prose.
  /// Acoustic coverage and timing remain diagnostics alongside the candidate.
  public func transcribeIndependent(
    _ samples: [Float], language: String? = nil, terms: [String] = [],
    coreSeconds: Double = 22, contextSeconds: Double = 1.5,
    firstTokenLogProbThreshold: Float? = nil, temperatureFallbackCount: Int = 0,
    detectLanguage: Bool? = nil,
    windowCompleted: (@Sendable (WhisperWindowResult) async throws -> Void)? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> WhisperWindowRecognition {
    guard samples.allSatisfy(\.isFinite) else { throw WhisperSetupError.invalidWindow }
    let duration = Double(samples.count) / 16000
    let plans = try Self.independentWindows(
      duration: duration, coreSeconds: coreSeconds, contextSeconds: contextSeconds)
    var windows: [WhisperWindowResult] = []
    for (index, plan) in plans.enumerated() {
      try Task.checkCancellation()
      let lower = max(0, Int((plan.audioStart * 16000).rounded(.down)))
      let upper = min(samples.count, Int((plan.audioEnd * 16000).rounded(.up)))
      let decoded = try await transcribe(
        Array(samples[lower..<upper]), language: language, terms: terms,
        vad: false, words: true,
        firstTokenLogProbThreshold: firstTokenLogProbThreshold,
        temperatureFallbackCount: temperatureFallbackCount, detectLanguage: detectLanguage,
        progress: { fraction in
          progress?((Double(index) + fraction) / Double(plans.count))
        })
      let shifted = RecognitionCoverage.shifted(decoded, by: Double(lower) / 16000)
      let result = Self.retainIndependentWindow(shifted, window: plan)
      windows.append(result)
      try await windowCompleted?(result)
      progress?(Double(index + 1) / Double(plans.count))
    }
    return WhisperWindowRecognition(
      passages: windows.flatMap(\.retained), windows: windows,
      timingIssues: windows.flatMap(\.timingIssues))
  }

  /// Nil language means actual language detection, rather than WhisperKit's
  /// English prefill. The pinned first-token threshold can discard an entire
  /// speech window before saving a lexical token; keep that abort disabled.
  /// Ordinary end-of-transcript decoding is unchanged. The threshold remains
  /// configurable for acoustic comparisons.
  public nonisolated static func decodingOptions(
    language: String? = nil, words: Bool = false, promptTokens: [Int]? = nil,
    vad: Bool = false, firstTokenLogProbThreshold: Float? = nil,
    temperatureFallbackCount: Int = 0, detectLanguage: Bool? = nil
  ) -> DecodingOptions {
    DecodingOptions(
      language: language, temperature: 0, temperatureFallbackCount: temperatureFallbackCount,
      detectLanguage: detectLanguage ?? (language == nil),
      skipSpecialTokens: true, wordTimestamps: words, promptTokens: promptTokens,
      firstTokenLogProbThreshold: firstTokenLogProbThreshold,
      chunkingStrategy: vad ? .vad : nil)
  }

  /// Adjacent cores cover the recording exactly once, including the tail.
  /// Context never expands a decoder call beyond 25 seconds.
  public nonisolated static func independentWindows(
    duration: Double, coreSeconds: Double = 22, contextSeconds: Double = 1.5
  ) throws -> [WhisperAudioWindow] {
    guard duration.isFinite, duration >= 0, duration <= 7200,
      coreSeconds.isFinite, coreSeconds > 0, coreSeconds <= 22,
      contextSeconds.isFinite, contextSeconds >= 0, contextSeconds <= 1.5,
      coreSeconds + contextSeconds * 2 <= 25
    else { throw WhisperSetupError.invalidWindow }
    var windows: [WhisperAudioWindow] = []
    var cursor: Double = 0
    while cursor < duration {
      let end = min(duration, cursor + coreSeconds)
      windows.append(
        WhisperAudioWindow(
          coreStart: cursor, coreEnd: end,
          audioStart: max(0, cursor - contextSeconds),
          audioEnd: min(duration, end + contextSeconds)))
      cursor = end
    }
    return windows
  }

  /// Canonical text is cut only with complete, chronological word timing.
  /// Ambiguous passages stay intact as candidates and are explicitly flagged;
  /// full alternatives are always retained for review, never silently discarded.
  public nonisolated static func retainIndependentWindow(
    _ passages: [WhisperPassage], window: WhisperAudioWindow
  ) -> WhisperWindowResult {
    var retained: [WhisperPassage] = []
    var issues: [RecognitionTimingIssue] = []
    for passage in passages {
      guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      guard let words = SpeakerAttribution.completeWords(passage, allowZeroDuration: true) else {
        if passage.start < window.coreEnd && passage.end > window.coreStart {
          retained.append(passage)
          issues.append(
            RecognitionTimingIssue(
              start: passage.start, end: passage.end,
              reason:
                "Independent-window candidate has incomplete canonical word timing; retained intact"
            ))
        }
        continue
      }
      let selected = words.filter {
        let midpoint = ($0.start + $0.end) / 2
        return midpoint >= window.coreStart && midpoint < window.coreEnd
      }
      guard let first = selected.first, let last = selected.last else { continue }
      if selected.contains(where: { $0.end <= $0.start }) {
        retained.append(passage)
        issues.append(
          RecognitionTimingIssue(
            start: passage.start, end: passage.end,
            reason: "Independent-window core has zero-duration lexical word timing; retained intact"
          ))
        continue
      }
      retained.append(
        WhisperPassage(
          text: selected.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
          start: first.start, end: last.end, words: selected))
    }
    return WhisperWindowResult(
      window: window, alternatives: passages, retained: retained, timingIssues: issues)
  }

}
public enum WhisperSetupError: LocalizedError {
  case missingModel
  case invalidWindow
  public var errorDescription: String? {
    switch self {
    case .missingModel:
      "Download the Whisper Turbo final recognition model in Settings first."
    case .invalidWindow:
      "Independent recognition needs finite audio up to two hours and windows of at most 25 seconds."
    }
  }
}
