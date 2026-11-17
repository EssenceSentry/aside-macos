import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import Aside

private final class ReliabilityProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var savedChunks: [CapturedChunk] = []
  private var savedIssues: [CaptureIssue] = []
  private var savedErrors: [String] = []
  var chunks: [CapturedChunk] { lock.withLock { savedChunks } }
  var issues: [CaptureIssue] { lock.withLock { savedIssues } }
  var errors: [String] { lock.withLock { savedErrors } }
  func append(_ chunk: CapturedChunk) { lock.withLock { savedChunks.append(chunk) } }
  func issue(_ issue: CaptureIssue) { lock.withLock { savedIssues.append(issue) } }
  func error(_ error: String) { lock.withLock { savedErrors.append(error) } }
}
private final class InjectedCaptureWrites: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  let failureAt: Int
  let commitBeforeFailure: Bool
  init(failureAt: Int, commitBeforeFailure: Bool = false) {
    self.failureAt = failureAt
    self.commitBeforeFailure = commitBeforeFailure
  }
  func write(_ file: AVAudioFile, _ buffer: AVAudioPCMBuffer) throws {
    let fails = lock.withLock {
      calls += 1
      return calls == failureAt
    }
    if fails {
      if commitBeforeFailure { try file.write(from: buffer) }
      throw AsideError("Injected storage failure")
    }
    try file.write(from: buffer)
  }
}
private func reliabilityBuffer(seconds: Double = 1, rate: Double = 16_000) throws
  -> AVAudioPCMBuffer
{
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)))
  buffer.frameLength = buffer.frameCapacity
  let samples = try #require(buffer.floatChannelData?[0])
  for i in 0..<Int(buffer.frameLength) { samples[i] = 0.1 * sin(Float(i) * 0.03) }
  return buffer
}
private func reliabilityDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aside-capture-reliability-" + newID())
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  return directory
}
private func reliabilityWriter(
  directory: URL, probe: ReliabilityProbe, injected: InjectedCaptureWrites? = nil
) -> ChunkWriter {
  ChunkWriter(
    directory: directory, origin: Date(timeIntervalSinceNow: -86_400), label: "Microphone",
    prefix: "mic",
    completed: { probe.append($0) }, failed: { probe.error($0) }, source: .microphone,
    onIssue: { probe.issue($0) },
    writePortion: { file, buffer in
      if let injected { try injected.write(file, buffer) } else { try file.write(from: buffer) }
    })
}

@Test func captureWriteFailureCommitsPartialFileAndPermanentlyDisablesSource() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(
    directory: directory, probe: probe, injected: InjectedCaptureWrites(failureAt: 2))
  let buffer = try reliabilityBuffer()
  #expect(writer.write(buffer, at: 90))
  #expect(!writer.write(buffer, at: 91))
  #expect(!writer.isHealthy)
  #expect(!writer.write(buffer, at: 92))
  writer.finish()
  #expect(probe.chunks.count == 1)
  let chunk = try #require(probe.chunks.first)
  #expect(chunk.offset == 90 && chunk.track.duration == 1)
  #expect(try AVAudioFile(forReading: chunk.url).length == 16_000)
  let issue = try #require(probe.issues.first)
  #expect(issue.source == .microphone && issue.kind == .writeFailed && issue.isFailure)
  #expect(issue.offset == 91 && issue.duration == 1)
  #expect(probe.issues.count == 1 && probe.errors.count == 1)
}

@Test func captureFailureAfterDiskWriteRetainsCommittedFramesWithoutClaimingTheirLoss() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(
    directory: directory, probe: probe,
    injected: InjectedCaptureWrites(failureAt: 1, commitBeforeFailure: true))
  #expect(!writer.write(try reliabilityBuffer(), at: 10))
  let chunk = try #require(probe.chunks.first)
  #expect(try AVAudioFile(forReading: chunk.url).length == 16_000)
  #expect(chunk.track.duration == 1)
  #expect(probe.issues.first?.offset == 11)
  #expect(probe.issues.first?.duration == 0)
}

@Test func captureTimestampGapPreservesRealOffsetsInsteadOfCompressingTime() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(directory: directory, probe: probe)
  let buffer = try reliabilityBuffer()
  #expect(writer.write(buffer, at: 90))
  #expect(writer.write(buffer, at: 93))
  writer.finish()
  #expect(probe.chunks.map(\.offset) == [90, 93])
  #expect(probe.chunks.map(\.track.duration) == [1, 1])
  #expect(try probe.chunks.reduce(0) { try $0 + AVAudioFile(forReading: $1.url).length } == 32_000)
  let issue = try #require(probe.issues.first)
  #expect(issue.kind == .timestampGap && !issue.isFailure)
  #expect(issue.offset == 91 && issue.duration == 2)
  #expect(issue.message.contains("No speech was recorded"))
  #expect(probe.errors.isEmpty)
}

@Test func captureBackwardTimestampRetainsAudioAndExplicitlyMarksOverlap() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(directory: directory, probe: probe)
  let buffer = try reliabilityBuffer()
  writer.write(buffer, at: 10)
  writer.write(buffer, at: 10.5)
  writer.finish()
  #expect(probe.chunks.map(\.offset) == [10, 10.5])
  #expect(probe.chunks.reduce(0) { $0 + $1.track.duration } == 2)
  #expect(probe.issues.first?.kind == .timestampOverlap)
  #expect(probe.issues.first?.offset == 10.5 && probe.issues.first?.duration == 0.5)
}

@Test func captureFormatChangeClosesTheOldFileWithoutLosingItsTimeOrSamples() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(directory: directory, probe: probe)
  writer.write(try reliabilityBuffer(rate: 16_000), at: 10)
  writer.write(try reliabilityBuffer(rate: 48_000), at: 11)
  writer.finish()
  #expect(probe.chunks.map(\.offset) == [10, 11])
  #expect(probe.chunks.map(\.track.duration) == [1, 1])
  #expect(try AVAudioFile(forReading: probe.chunks[0].url).length == 16_000)
  #expect(try AVAudioFile(forReading: probe.chunks[1].url).length == 48_000)
  #expect(probe.issues.map(\.kind) == [.formatChanged])
}

@Test func captureSourceStopFinalizesPartialSamplesOnceAndSuppressesFutureWrites() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(directory: directory, probe: probe)
  let buffer = try reliabilityBuffer(seconds: 0.25)
  writer.write(buffer, at: 3)
  writer.fail(offset: 3.25, message: "Device disconnected")
  writer.fail(offset: 4, message: "Repeated notification")
  #expect(!writer.write(buffer, at: 4))
  writer.finish()
  #expect(probe.chunks.count == 1 && probe.chunks[0].track.duration == 0.25)
  #expect(probe.issues.map(\.kind) == [.sourceStopped])
  #expect(probe.errors == ["Device disconnected"])
}

@Test func captureUnknownSourceTimeIsFlaggedOnceAndUsesExplicitMonotonicFallback() throws {
  let directory = try reliabilityDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let probe = ReliabilityProbe()
  let writer = reliabilityWriter(directory: directory, probe: probe)
  let buffer = try reliabilityBuffer(seconds: 0.5)
  writer.write(buffer, fallbackOffset: 7)
  writer.write(buffer, fallbackOffset: 7.5)
  #expect(writer.isHealthy)
  writer.finish()
  #expect(probe.chunks.first?.offset == 7 && probe.chunks.first?.track.duration == 1)
  #expect(probe.issues.map(\.kind) == [.timestampUnavailable])
  #expect(probe.errors.isEmpty)
}

@Test func microphoneAndSystemTimestampsShareOneHostClockOrigin() throws {
  let timeline = CaptureTimeline(timelineOffset: 90, hostOrigin: 1_000)
  let microphoneTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1_000.25))
  let systemTime = CMTime(seconds: 1_000.25, preferredTimescale: 1_000_000_000)
  let mic = try #require(timeline.offset(for: microphoneTime))
  let system = try #require(timeline.offset(for: systemTime, from: CMClockGetHostTimeClock()))
  #expect(abs(mic - 90.25) < 0.000_001)
  #expect(abs(system - mic) < 0.000_001)
  #expect(timeline.offset(for: AVAudioTime(sampleTime: 4_000, atRate: 16_000)) == nil)
  #expect(timeline.offset(for: .invalid, from: CMClockGetHostTimeClock()) == nil)
  #expect(timeline.offset(for: systemTime, from: nil) == nil)
}

@Test func captureIssuePersistsSourceAndMissingIntervalWithoutChangingEvidenceMeaning() throws {
  let issue = CaptureIssue(
    source: .systemAudio, kind: .timestampGap, offset: 17, duration: 2.5,
    message: "Missing capture interval")
  let restored = try JSONDecoder().decode(CaptureIssue.self, from: JSONEncoder().encode(issue))
  #expect(restored == issue)
  #expect(restored.source.rawValue == "systemAudio")
  #expect(!restored.isFailure)
}
