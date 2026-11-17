import FluidAudio
import Foundation
import Testing

@testable import Aside

private func piece(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
  TokenTiming(token: token, tokenId: 1, startTime: start, endTime: end, confidence: 0.95)
}
private func revision(
  _ job: UUID, _ ordinal: Int, previous: Int, retained: Int, stable: Int,
  tokens: [TokenTiming] = [], end: Bool = false
) -> SlidingWindowTokenUpdate {
  let revision = SlidingWindowTokenRevision(
    jobID: job, ordinal: ordinal,
    previousTokenCount: previous, retainedTokenCount: retained, stableTokenCount: stable,
    window: 0..<48000, center: 0..<48000, isTerminal: end)
  return SlidingWindowTokenUpdate(tokens: tokens, revision: revision)
}

@Test func streamingStableCaptionGroupsNeverChangeWhenVolatileTailRevises() throws {
  let job = UUID()
  var state = StreamingCaptionReducer(generation: "g", source: "Microphone")
  #expect(try state.register(id: "track:A", offset: 30.25, samples: 16000))
  #expect(try state.register(id: "track:B", offset: 31.25, samples: 32000))
  #expect(try !state.register(id: "track:A", offset: 30.25, samples: 16000))
  try state.apply(
    revision(
      job, 1, previous: 0, retained: 0, stable: 1,
      tokens: [piece("▁Do", 0.1, 0.3), piece("▁approve", 0.35, 0.6)]))
  let first = state.snapshot
  #expect(first.stableSegments.map(\.rawText) == ["Do"])
  #expect(first.stableSegments[0].start == 30.35)
  #expect(first.stableSegments[0].id == "track:A:-1" && !first.isTerminal)
  try state.apply(
    revision(
      job, 2, previous: 2, retained: 1, stable: 2,
      tokens: [piece("▁not", 0.4, 0.6), piece("▁ap", 1.1, 1.2), piece("prove", 1.2, 1.5)]))
  #expect(state.snapshot.stableSegments.prefix(1).elementsEqual(first.stableSegments))
  #expect(state.snapshot.stableSegments.map(\.rawText) == ["Do", "not"])
  #expect(throws: AsideError.self) {
    try state.apply(revision(job, 3, previous: 4, retained: 1, stable: 2))
  }
  try state.apply(revision(job, 3, previous: 4, retained: 4, stable: 4, end: true))
  let final = state.snapshot
  #expect(final.isTerminal && final.trackIDs == ["track:A", "track:B"])
  #expect(final.stableSegments.map(\.rawText) == ["Do", "not", "approve"])
  #expect(final.stableSegments.map(\.id) == ["track:A:-1", "track:A:-2", "track:B:-3"])
  #expect(final.stableSegments.last?.start == 31.35 && final.stableSegments.last?.end == 31.75)
  #expect(throws: AsideError.self) {
    try state.apply(revision(job, 4, previous: 4, retained: 4, stable: 4, end: true))
  }
}

@Test func streamingRejectsTimingOutsideAudioAndNeverMarksAFailedRevisionTerminal() throws {
  var state = StreamingCaptionReducer(generation: "g", source: "System audio")
  #expect(try state.register(id: "remote", offset: 100, samples: 16000))
  #expect(throws: CaptionDiscontinuity.self) {
    try state.register(id: "overlap", offset: 100.3, samples: 16000)
  }
  #expect(throws: CaptionDiscontinuity.self) {
    try state.register(id: "gap", offset: 102, samples: 16000)
  }
  #expect(throws: AsideError.self) {
    try state.apply(
      revision(
        UUID(), 1, previous: 0, retained: 0, stable: 1,
        tokens: [piece("▁fabricated", 2, 2.4)], end: true))
  }
  #expect(state.snapshot.stableSegments.isEmpty && !state.snapshot.isTerminal)
  #expect(state.snapshot.trackIDs == ["remote"])
}
