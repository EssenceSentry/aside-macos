import AVFoundation
import FluidAudio
import Foundation

public struct SpeechRegion: Codable, Sendable, Equatable {
  public var start: Double
  public var end: Double
  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

public struct PreparationProfile: Codable, Sendable, Equatable {
  public var threshold: Float
  public var retainedPause: Double
  public var speechPadding: Double
  public var normalize: Bool
  public var shortenSilences: Bool
  public init(
    threshold: Float = 0.5, retainedPause: Double = 0.35, speechPadding: Double = 0.25,
    normalize: Bool = false, shortenSilences: Bool = true
  ) {
    self.threshold = threshold
    self.retainedPause = retainedPause
    self.speechPadding = speechPadding
    self.normalize = normalize
    self.shortenSilences = shortenSilences
  }
}

public struct AudioTimeSpan: Codable, Sendable, Equatable {
  public var outputStart: Double
  public var outputEnd: Double
  public var sourceStart: Double
  public var sourceEnd: Double
}

public struct PreparationMetrics: Codable, Sendable {
  public var originalSeconds: Double
  public var preparedSeconds: Double
  public var speechSeconds: Double
  public var gain: Float
  public var originalPeak: Float
  public var clippingFraction: Double
  public var detectedRegions: Int
}

public struct PreparedAudio: Sendable {
  public var samples: [Float]
  public var timeMap: [AudioTimeSpan]
  public var metrics: PreparationMetrics
  public func originalTime(_ time: Double) -> Double {
    guard let span = timeMap.first(where: { time >= $0.outputStart && time < $0.outputEnd }) else {
      return time <= 0 ? timeMap.first?.sourceStart ?? 0 : timeMap.last?.sourceEnd ?? 0
    }
    return span.sourceStart
      + min(max(0, time - span.outputStart), span.sourceEnd - span.sourceStart)
  }
}

/// Uses trained Silero VAD; the profile controls conservative inference-time conditioning.
/// Original samples are never modified. Speech fillers are speech and are retained.
public actor AudioPreparationModel {
  public static let sampleRate = 16_000.0
  private let directory: URL
  private var detectors: [String: VadManager] = [:]
  public init(directory: URL) { self.directory = directory }

  public func prepare(
    _ samples: [Float], profile: PreparationProfile = .init(),
    allowDownload: Bool = false
  ) async throws -> PreparedAudio {
    guard samples.allSatisfy(\.isFinite) else { throw PreparationError.invalidSamples }
    guard profile.threshold > 0, profile.threshold < 1, profile.retainedPause >= 0,
      profile.speechPadding >= 0
    else { throw PreparationError.invalidProfile }
    if samples.isEmpty { return Self.render(samples, regions: [], profile: profile) }
    let regions = try await speechRegions(
      samples, threshold: profile.threshold, allowDownload: allowDownload)
    return Self.render(samples, regions: regions, profile: profile)
  }

  /// Acoustic speech support without editing audio or assigning identities.
  /// Cached models are required unless setup explicitly authorizes a download.
  public func speechRegions(
    _ samples: [Float], threshold: Float = 0.5, allowDownload: Bool = false
  ) async throws -> [SpeechRegion] {
    guard samples.allSatisfy(\.isFinite) else { throw PreparationError.invalidSamples }
    guard threshold > 0, threshold < 1 else { throw PreparationError.invalidProfile }
    if samples.isEmpty { return [] }
    let cacheKey = String(threshold)
    let detector: VadManager
    if let ready = detectors[cacheKey] {
      detector = ready
    } else {
      let previous = ModelHub.offlineMode
      ModelHub.offlineMode = !allowDownload
      defer { ModelHub.offlineMode = previous }
      detector = try await VadManager(
        config: VadConfig(defaultThreshold: threshold), modelDirectory: directory)
      detectors[cacheKey] = detector
    }
    // Padding belongs to rendering. Coverage uses actual acoustic support.
    let segmentation = VadSegmentationConfig(
      minSpeechDuration: 0.08, minSilenceDuration: 0.65,
      maxSpeechDuration: 120, speechPadding: 0,
      silenceThresholdForSplit: max(0.01, threshold - 0.15))
    let predictions = try await detector.segmentSpeech(samples, config: segmentation)
    return predictions.map { SpeechRegion(start: $0.startTime, end: $0.endTime) }
  }

  public nonisolated static func render(
    _ samples: [Float], regions: [SpeechRegion],
    profile: PreparationProfile
  ) -> PreparedAudio {
    let rate = sampleRate
    let duration = Double(samples.count) / rate
    let finite = samples.map { $0.isFinite ? $0 : 0 }
    let peak = finite.reduce(Float(0)) { max($0, abs($1)) }
    let clipped = finite.filter { abs($0) >= 0.999 }.count
    let clamped = regions.compactMap { region -> Range<Int>? in
      let lower = max(0, Int(((region.start - profile.speechPadding) * rate).rounded(.down)))
      let upper = min(finite.count, Int(((region.end + profile.speechPadding) * rate).rounded(.up)))
      return lower < upper ? lower..<upper : nil
    }.sorted { $0.lowerBound < $1.lowerBound }
    var speech: [Range<Int>] = []
    for range in clamped {
      if let last = speech.last, range.lowerBound <= last.upperBound {
        speech[speech.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        speech.append(range)
      }
    }
    // No detected voice is not proof the file is empty. Keep it intact for a
    // recognizer/review rather than deleting quiet or unusually accented speech.
    var kept: [Range<Int>] = []
    if !profile.shortenSilences || speech.isEmpty {
      if !finite.isEmpty { kept = [0..<finite.count] }
    } else {
      for range in speech {
        if let last = kept.last {
          let gap = range.lowerBound - last.upperBound
          let retain = min(gap, Int((profile.retainedPause * rate).rounded()))
          if gap <= retain {
            kept[kept.count - 1] = last.lowerBound..<range.upperBound
          } else {
            let left = retain / 2
            let right = retain - left
            kept[kept.count - 1] = last.lowerBound..<(last.upperBound + left)
            kept.append((range.lowerBound - right)..<range.upperBound)
          }
        } else {
          kept.append(range)
        }
      }
    }
    var energy: Double = 0
    var voicedCount = 0
    for range in speech {
      for index in range { energy += Double(finite[index]) * Double(finite[index]) }
      voicedCount += range.count
    }
    let rms = voicedCount > 0 ? sqrt(energy / Double(voicedCount)) : 0
    let gain: Float =
      profile.normalize && rms > 0.0001 && peak > 0
      ? max(0, min(4, min(Float(0.08 / rms), 0.97 / peak))) : 1
    var output: [Float] = []
    var map: [AudioTimeSpan] = []
    for range in kept {
      let begin = Double(output.count) / rate
      output.append(contentsOf: finite[range].map { $0 * gain })
      map.append(
        AudioTimeSpan(
          outputStart: begin, outputEnd: Double(output.count) / rate,
          sourceStart: Double(range.lowerBound) / rate, sourceEnd: Double(range.upperBound) / rate))
    }
    return PreparedAudio(
      samples: output, timeMap: map,
      metrics: PreparationMetrics(
        originalSeconds: duration, preparedSeconds: Double(output.count) / rate,
        speechSeconds: Double(voicedCount) / rate, gain: gain, originalPeak: peak,
        clippingFraction: finite.isEmpty ? 0 : Double(clipped) / Double(finite.count),
        detectedRegions: regions.count))
  }

  public nonisolated static func load(_ url: URL) throws -> [Float] {
    try AudioConverter().resampleAudioFile(url)
  }
  public nonisolated static func write(_ samples: [Float], to url: URL) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
    else {
      throw PreparationError.invalidSamples
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { values in
      if let base = values.baseAddress {
        buffer.floatChannelData![0].update(from: base, count: samples.count)
      }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum PreparationError: LocalizedError {
  case invalidSamples, invalidProfile
  public var errorDescription: String? {
    switch self {
    case .invalidSamples: "The audio could not be normalized into usable samples."
    case .invalidProfile: "The audio preparation settings are invalid."
    }
  }
}

extension AudioPreparationModel {
  public nonisolated static func fillerRegions(from words: [WordTiming]) -> [SpeechRegion] {
    let fillers: Set<String> = ["um", "uh", "umm", "ummm", "erm", "ehm", "emm", "hmm"]
    return words.filter { fillers.contains($0.word.lowercased().filter(\.isLetter)) }
      .map { SpeechRegion(start: $0.startTime, end: $0.endTime) }
  }
  /// An experimental second pass: silence only filler spans identified by ASR.
  /// This can remove a misrecognized word, so it is benchmarked separately and
  /// never enabled by the production profile automatically.
  public nonisolated static func maskFillers(_ samples: [Float], regions: [SpeechRegion]) -> [Float]
  {
    var output = samples
    for region in regions {
      let start = max(0, Int((region.start * sampleRate).rounded()))
      let end = min(output.count, Int((region.end * sampleRate).rounded()))
      guard start < end else { continue }
      let fade = min(80, (end - start) / 4)
      for index in start..<end {
        let edge = min(index - start, end - 1 - index)
        output[index] *= fade > 0 && edge < fade ? 1 - Float(edge) / Float(fade) : 0
      }
    }
    return output
  }
}
