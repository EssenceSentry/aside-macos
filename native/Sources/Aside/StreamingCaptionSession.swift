import AVFoundation
import FluidAudio
import Foundation

/// Immutable recognition wording and measured source-clock timing. Acoustic
/// attribution may update only the speaker, without changing the caption ID.
struct CaptionWord: Codable, Sendable, Equatable {
  var text: String
  var start: Double
  var end: Double
  var speaker: String? = nil
}

/// One source and recording generation. Only terminal track IDs may enter the
/// transcription ledger. On failure, preserve captured files and committed text
/// and route these tracks to final recognition instead of replaying their ASR.
struct LiveCaptionSnapshot: Sendable {
  let generation: String
  let source: String
  let stableSegments: [Segment]
  let trackIDs: [String]
  let isTerminal: Bool
}

protocol LiveCaptionSession: Sendable {
  func append(_ chunk: CapturedChunk) async throws
  func finish() async throws -> LiveCaptionSnapshot
  func currentSnapshot() async -> LiveCaptionSnapshot
  func cancel() async
}

struct CaptionDiscontinuity: LocalizedError {
  var errorDescription: String? {
    "The source clock changed. Flush this caption stream and start another at the new track."
  }
}

/// Token seconds are relative to the decoder input. Retain each original
/// track's actual clock, including the sub-millisecond offset rounding.
struct StreamingCaptionReducer {
  let generation: String
  let source: String
  private struct Track {
    let id: String
    let offset: Double
    let frames: Range<Int>
  }
  private var tracks: [Track] = []
  private var job: UUID?
  private var ordinal = 0
  private var stable = 0
  private var volatileTokens: [TokenTiming] = []
  private var segments: [Segment] = []
  private var terminal = false
  init(generation: String, source: String) {
    self.generation = generation
    self.source = source
  }
  var snapshot: LiveCaptionSnapshot {
    LiveCaptionSnapshot(
      generation: generation, source: source, stableSegments: segments,
      trackIDs: tracks.map(\.id), isTerminal: terminal)
  }
  mutating func register(id: String, offset: Double, samples: Int) throws -> Bool {
    guard !terminal, !id.isEmpty, offset.isFinite, offset >= 0, samples > 0 else {
      throw AsideError("Invalid live capture track.")
    }
    if let existing = tracks.first(where: { $0.id == id }) {
      guard existing.offset == offset, existing.frames.count == samples else {
        throw CaptionDiscontinuity()
      }
      return false
    }
    let head = tracks.last?.frames.upperBound ?? 0
    if let previous = tracks.last,
      abs(offset - (previous.offset + Double(previous.frames.count) / 16000)) > 0.001
    {
      throw CaptionDiscontinuity()
    }
    let (tail, overflow) = head.addingReportingOverflow(samples)
    guard !overflow else { throw AsideError("Live caption timeline overflow.") }
    tracks.append(Track(id: id, offset: offset, frames: head..<tail))
    return true
  }

  mutating func apply(_ update: SlidingWindowTokenUpdate) throws {
    let r = update.revision
    guard !terminal, job == nil || job == r.jobID, r.ordinal == ordinal + 1,
      r.previousTokenCount == stable + volatileTokens.count,
      r.retainedTokenCount >= stable, r.retainedTokenCount <= r.previousTokenCount,
      r.stableTokenCount >= stable
    else { throw AsideError("The caption decoder revised an immutable prefix.") }
    var candidates = Array(volatileTokens.prefix(r.retainedTokenCount - stable))
    candidates.append(contentsOf: update.tokens)
    let newlyStable = r.stableTokenCount - stable
    guard newlyStable <= candidates.count, !r.isTerminal || newlyStable == candidates.count else {
      throw AsideError("The caption decoder returned an inconsistent stable-token count.")
    }
    // The SDK's stableStreamingTokenCount excludes its entire trailing word.
    // Each newly stable slice can therefore be rendered without guessing a
    // continuation. A publication never extends an already saved segment.
    let words = buildWordTimings(from: Array(candidates.prefix(newlyStable)))
    var additions: [Segment] = []
    var group: [WordTiming] = []
    var groupOwner: String?
    func track(at seconds: Double, end: Bool) -> Track? {
      guard seconds.isFinite, seconds >= 0, let last = tracks.last,
        seconds <= Double(last.frames.upperBound) / 16000
      else { return nil }
      let frame = seconds * 16000
      return tracks.first { piece in
        let lo = Double(piece.frames.lowerBound)
        let hi = Double(piece.frames.upperBound)
        return end ? (frame > lo && frame <= hi) : (frame >= lo && frame < hi)
      }
    }
    func flush() {
      guard let first = group.first, let last = group.last, let owner = groupOwner else { return }
      let text = group.map(\.word).joined(separator: " ")
      // Negative integers are disjoint from the original per-chunk ASR indexes
      // while preserving the existing trackID:integer provenance contract.
      additions.append(
        Segment(
          id: owner + ":-" + String(segments.count + additions.count + 1),
          start: first.startTime, end: last.endTime, speaker: source, rawText: text, text: text,
          status: "raw", revision: 0, corrections: [],
          captionWords: group.map {
            CaptionWord(text: $0.word, start: $0.startTime, end: $0.endTime, speaker: source)
          }))
      group.removeAll(keepingCapacity: true)
    }
    for word in words {
      guard word.endTime >= word.startTime,
        let owner = track(at: word.startTime, end: false),
        let ending = word.endTime == word.startTime ? owner : track(at: word.endTime, end: true)
      else { throw AsideError("A stable caption has no measured time in its captured audio.") }
      let start = owner.offset + (word.startTime - Double(owner.frames.lowerBound) / 16000)
      let end = ending.offset + (word.endTime - Double(ending.frames.lowerBound) / 16000)
      guard end >= start else { throw CaptionDiscontinuity() }
      if groupOwner != owner.id { flush() }
      groupOwner = owner.id
      group.append(WordTiming(word: word.word, startTime: start, endTime: end))
      if end - (group.first?.startTime ?? start) >= 6 || word.word.hasSuffix(".")
        || word.word.hasSuffix("?")
      {
        flush()
      }
    }
    flush()
    segments.append(contentsOf: additions)
    volatileTokens = Array(candidates.dropFirst(newlyStable))
    stable = r.stableTokenCount
    job = r.jobID
    ordinal = r.ordinal
    terminal = r.isTerminal
  }
}

actor StreamingCaptionSession: LiveCaptionSession {
  typealias Update = @Sendable (LiveCaptionSnapshot) async throws -> Void
  private let manager: SlidingWindowAsrManager
  private let onUpdate: Update
  private var reducer: StreamingCaptionReducer
  private var consumer: Task<Void, Error>?
  private var lastFeed: Task<Void, Never>?
  private var completion: Task<LiveCaptionSnapshot, Error>?
  private var acknowledgedTerminal = false
  private var closed = false
  private var failure: Error?
  private init(
    manager: SlidingWindowAsrManager, source: String, generation: String, onUpdate: @escaping Update
  ) {
    self.manager = manager
    self.onUpdate = onUpdate
    reducer = StreamingCaptionReducer(generation: generation, source: source)
  }
  static func open(
    models: AsrModels, source: String, generation: String,
    onUpdate: @escaping Update
  ) async throws -> StreamingCaptionSession {
    let config = SlidingWindowAsrConfig(
      chunkSeconds: 5, hypothesisChunkSeconds: 1,
      leftContextSeconds: 6, rightContextSeconds: 1, minContextForConfirmation: 10,
      confirmationThreshold: 0.80)
    try config.validate()
    let manager = SlidingWindowAsrManager(config: config)
    try await manager.loadModels(models)
    try await manager.startStreaming()
    let updates = await manager.tokenUpdates
    let session = StreamingCaptionSession(
      manager: manager, source: source, generation: generation, onUpdate: onUpdate)
    await session.subscribe(updates)
    return session
  }
  private func subscribe(_ updates: AsyncThrowingStream<SlidingWindowTokenUpdate, Error>) {
    consumer = Task { [weak self] in
      do {
        for try await update in updates {
          try Task.checkCancellation()
          try await self?.receive(update)
        }
      } catch {
        await self?.recordFailure(error)
        throw error
      }
    }
  }
  private func recordFailure(_ error: Error) { failure = error }
  private func receive(_ update: SlidingWindowTokenUpdate) async throws {
    try Task.checkCancellation()
    let previous = reducer.snapshot.stableSegments.count
    try reducer.apply(update)
    let snapshot = reducer.snapshot
    if !snapshot.isTerminal && snapshot.stableSegments.count > previous {
      try await onUpdate(snapshot)
    }
  }

  func append(_ chunk: CapturedChunk) async throws {
    if let failure { throw failure }
    guard !closed, chunk.speaker == reducer.source, chunk.track.label == reducer.source else {
      throw AsideError("This caption session cannot accept this source.")
    }
    let samples = try AudioConverter().resampleAudioFile(chunk.url)
    guard samples.count <= Int(UInt32.max), samples.allSatisfy(\.isFinite),
      let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw AsideError("Capture could not be converted for live captions.") }
    guard try reducer.register(id: chunk.track.id, offset: chunk.offset, samples: samples.count)
    else { return }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { values in
      buffer.floatChannelData![0].update(from: values.baseAddress!, count: samples.count)
    }
    let previous = lastFeed
    let feed = Task { [manager] in
      await previous?.value
      await manager.streamAudio(buffer)
    }
    lastFeed = feed
    await feed.value
    if let failure { throw failure }
  }
  func currentSnapshot() -> LiveCaptionSnapshot {
    let snapshot = reducer.snapshot
    return LiveCaptionSnapshot(
      generation: snapshot.generation, source: snapshot.source,
      stableSegments: snapshot.stableSegments, trackIDs: snapshot.trackIDs,
      isTerminal: acknowledgedTerminal)
  }
  func finish() async throws -> LiveCaptionSnapshot {
    if let completion { return try await completion.value }
    guard !closed else { throw CancellationError() }
    closed = true
    let task = Task { try await self.drain() }
    completion = task
    return try await task.value
  }
  private func drain() async throws -> LiveCaptionSnapshot {
    await lastFeed?.value
    do {
      let final = try await manager.finish()
      try await consumer?.value
      try Task.checkCancellation()
      if let failure { throw failure }
      let snapshot = reducer.snapshot
      let rendered = snapshot.stableSegments.map(\.rawText).joined(separator: " ")
      func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
      guard snapshot.isTerminal, words(rendered) == words(final) else {
        throw AsideError("Stable captions could not be reconciled with the final decoder text.")
      }
      try await onUpdate(snapshot)
      try Task.checkCancellation()
      acknowledgedTerminal = true
      return snapshot
    } catch {
      consumer?.cancel()
      await manager.cancel()
      _ = await consumer?.result
      failure = error
      throw error
    }
  }
  func cancel() async {
    closed = true
    failure = CancellationError()
    completion?.cancel()
    consumer?.cancel()
    await lastFeed?.value
    await manager.cancel()
    _ = await consumer?.result
  }
}
