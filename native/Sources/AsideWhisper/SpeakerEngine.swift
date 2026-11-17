import Foundation
import SpeakerKit

public struct SpeakerTurn: Codable, Sendable, Equatable {
  public var speaker: String
  public var start: Double
  public var end: Double
  public init(speaker: String, start: Double, end: Double) {
    self.speaker = speaker
    self.start = start
    self.end = end
  }
}

public struct SpeakerReference: Sendable {
  public var speaker: String
  public var samples: [Float]
  public init(speaker: String, samples: [Float]) {
    self.speaker = speaker
    self.samples = samples
  }
}
public struct SpeakerReferenceSpan: Sendable {
  public var speaker: String
  public var start: Double
  public var end: Double
  public init(speaker: String, start: Double, end: Double) {
    self.speaker = speaker
    self.start = start
    self.end = end
  }
}
public struct SpeakerAnalysis: Codable, Sendable {
  public var turns: [SpeakerTurn]
  public var referenceMatched: Bool
  public var referenceShare: Double
  public var matchedSpeakers: [String]? = nil
}

/// Local acoustic clusters anchored to participant names only through explicitly
/// saved solo recordings. Transcript text never enrolls or identifies a voice.
public actor SpeakerEngine {
  private let directory: URL
  private var pipeline: SpeakerKit?
  private var loading: Task<Void, Error>?
  public init(root: URL) { directory = root.appendingPathComponent("models/speakers") }
  private func savedFolder() -> URL? {
    guard
      let relative = try? String(
        contentsOf: directory.appendingPathComponent("ready-path"), encoding: .utf8),
      !relative.contains(".."), !relative.hasPrefix("/"), !relative.isEmpty
    else { return nil }
    let path = directory.appendingPathComponent(relative)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
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
    guard download || folder != nil else { throw SpeakerSetupError.missingModel }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let config = PyannoteConfig(
      downloadBase: directory.path, modelFolder: folder?.path,
      download: download && folder == nil, load: true, verbose: false,
      concurrentSegmenterWorkers: 2, concurrentEmbedderWorkers: 2)
    let loaded = try await SpeakerKit(config)
    guard let manager = loaded.diarizer as? SpeakerKitDiarizer,
      let modelFolder = manager.modelPath ?? manager.modelFolder,
      modelFolder.path.hasPrefix(directory.path + "/")
    else { throw SpeakerSetupError.missingModel }
    let relative = String(modelFolder.path.dropFirst(directory.path.count + 1))
    let marker = directory.appendingPathComponent("ready-path")
    if (try? String(contentsOf: marker, encoding: .utf8)) != relative {
      try relative.write(to: marker, atomically: true, encoding: .utf8)
    }
    pipeline = loaded
  }
  public func diarize(
    _ samples: [Float], speakerCount: Int? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> [SpeakerTurn] {
    try await prepare(download: false)
    guard let pipeline else { throw SpeakerSetupError.missingModel }
    let result = try await pipeline.diarize(
      audioArray: samples,
      options: PyannoteDiarizationOptions(
        numberOfSpeakers: speakerCount, useExclusiveReconciliation: false),
      progressCallback: { value in progress?(value.fractionCompleted) })
    return result.segments.map { value in
      let ids = value.speaker.speakerIds
      let name =
        ids.isEmpty ? "Unknown speaker" : ids.map { "Speaker \($0 + 1)" }.joined(separator: " + ")
      return SpeakerTurn(speaker: name, start: Double(value.startTime), end: Double(value.endTime))
    }.sorted { $0.start < $1.start }
  }
  /// Joint clustering anchors this recording to a known solo reference without
  /// assuming a universal cosine-distance threshold across microphones.
  public func analyze(
    _ samples: [Float], reference: [Float]? = nil, references: [SpeakerReference] = [],
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> SpeakerAnalysis {
    var all = references
    if let reference, reference.count >= 16000 * 8 {
      all.insert(SpeakerReference(speaker: "You", samples: reference), at: 0)
    }
    var grouped: [String: [Float]] = [:]
    for item in all
    where item.samples.count >= 16000 * 8 && item.samples.allSatisfy(\.isFinite) {
      if grouped[item.speaker] != nil {
        grouped[item.speaker]! += [Float](repeating: 0, count: 4000)
      }
      grouped[item.speaker, default: []] += item.samples
    }
    if grouped.isEmpty {
      return SpeakerAnalysis(
        turns: try await diarize(samples, progress: progress), referenceMatched: false,
        referenceShare: 0)
    }
    var combined: [Float] = []
    var spans: [SpeakerReferenceSpan] = []
    for name in grouped.keys.sorted() {
      let start = Double(combined.count) / 16000
      combined += grouped[name]!
      spans.append(
        SpeakerReferenceSpan(speaker: name, start: start, end: Double(combined.count) / 16000))
      combined += [Float](repeating: 0, count: 32000)
    }
    let offset = Double(combined.count) / 16000
    combined += samples
    return Self.anchor(
      turns: try await diarize(combined, progress: progress), references: spans,
      recordingOffset: offset)
  }
  public nonisolated static func anchor(
    turns: [SpeakerTurn], referenceDuration: Double, recordingOffset: Double
  ) -> SpeakerAnalysis {
    anchor(
      turns: turns,
      references: [SpeakerReferenceSpan(speaker: "You", start: 0, end: referenceDuration)],
      recordingOffset: recordingOffset)
  }
  public nonisolated static func anchor(
    turns: [SpeakerTurn], references: [SpeakerReferenceSpan], recordingOffset: Double
  ) -> SpeakerAnalysis {
    guard recordingOffset.isFinite, recordingOffset >= 0,
      references.allSatisfy({
        $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end - $0.start >= 8
          && $0.end <= recordingOffset
      })
    else { return SpeakerAnalysis(turns: [], referenceMatched: false, referenceShare: 0) }
    let valid = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
    func scores(_ start: Double, _ end: Double) -> [String: Double] {
      var ranges: [String: [Range<Double>]] = [:]
      for turn in valid where !turn.speaker.contains(" + ") && turn.speaker != "Unknown speaker" {
        let lower = max(start, turn.start)
        let upper = min(end, turn.end)
        if lower < upper { ranges[turn.speaker, default: []].append(lower..<upper) }
      }
      return ranges.mapValues {
        SpeakerAttribution.union($0).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
      }
    }
    var nominations: [String: [String]] = [:]
    var shares: [String: Double] = [:]
    for reference in references {
      let ranked = scores(reference.start, reference.end).sorted {
        $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
      }
      let total = ranked.reduce(0) { $0 + $1.value }
      let share = (ranked.first?.value ?? 0) / max(0.001, total)
      shares[reference.speaker] = share
      let midpoint = (reference.start + reference.end) / 2
      let first = scores(reference.start, midpoint)
      let second = scores(midpoint, reference.end)
      let minimum = min(2, (reference.end - reference.start) * 0.15)
      if let winner = ranked.first?.key, total >= min(8, (reference.end - reference.start) * 0.5),
        share >= 0.9,
        (first[winner] ?? 0) >= minimum, (second[winner] ?? 0) >= minimum,
        first.values.allSatisfy({ $0 <= (first[winner] ?? 0) }),
        second.values.allSatisfy({ $0 <= (second[winner] ?? 0) })
      {
        nominations[winner, default: []].append(reference.speaker)
      }
    }
    let names = nominations.compactMapValues { values -> String? in
      let unique = Set(values)
      return unique.count == 1 ? unique.first : nil
    }
    let reservedNames = Set(references.map(\.speaker))
    func displayName(_ cluster: String) -> String {
      if let name = names[cluster] { return name }
      var anonymous = cluster
      while reservedNames.contains(anonymous) { anonymous = "Unmatched " + anonymous }
      return anonymous
    }
    let output = valid.compactMap { turn -> SpeakerTurn? in
      guard turn.end > recordingOffset else { return nil }
      let label = turn.speaker.components(separatedBy: " + ").map(displayName).sorted()
        .joined(separator: " + ")
      return SpeakerTurn(
        speaker: label, start: max(0, turn.start - recordingOffset), end: turn.end - recordingOffset
      )
    }.sorted { $0.start < $1.start }
    // Determine matches from the original cluster IDs, before display-name
    // substitution: an explicitly saved name may itself be “Speaker 1”.
    let matched = Set(
      valid.filter { $0.end > recordingOffset }.flatMap {
        $0.speaker.components(separatedBy: " + ").compactMap { names[$0] }
      })
    return SpeakerAnalysis(
      turns: output, referenceMatched: matched.contains("You"), referenceShare: shares["You"] ?? 0,
      matchedSpeakers: matched.sorted())
  }

}
public enum SpeakerSetupError: LocalizedError {
  case missingModel
  public var errorDescription: String? {
    "Download the local speaker identification model in Settings first."
  }
}
