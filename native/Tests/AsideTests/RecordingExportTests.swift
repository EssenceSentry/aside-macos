import AVFoundation
import Foundation
import Testing

@testable import Aside

private func fixture(_ body: (URL, URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aside-export-" + newID())
  let meeting = root.appendingPathComponent("meeting")
  try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root, meeting)
}
private func makeAudio(_ url: URL, rate: Double, channels: UInt32, seconds: Double, value: Float)
  throws
{
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
  let count = AVAudioFrameCount((seconds * rate).rounded())
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
  buffer.frameLength = count
  for channel in 0..<Int(channels) {
    for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = value }
  }
  let file = try AVAudioFile(forWriting: url, settings: format.settings)
  try file.write(from: buffer)
}
@Test func originalExportPreservesTimelineChannelsAndInputWhenRatesChange() throws {
  try fixture { root, directory in
    let a = "mic-00000000.250-a.caf"
    let b = "mic-00000001.000-b.caf"
    try makeAudio(
      directory.appendingPathComponent(a), rate: 16000, channels: 1, seconds: 0.5, value: 0.25)
    try makeAudio(
      directory.appendingPathComponent(b), rate: 48000, channels: 2, seconds: 0.5, value: -0.5)
    let original = try Data(contentsOf: directory.appendingPathComponent(a))
    var meeting = Meeting.make(title: "Export", context: "", language: "en")
    meeting.duration = 2
    meeting.audioTracks = [
      AudioTrack(id: "b", label: "Microphone", filename: b, duration: 0.5),
      AudioTrack(id: "a", label: "Microphone", filename: a, duration: 0.5),
    ]
    let output = root.appendingPathComponent("original.wav")
    // Exercise replacement, and confirm its prior bytes survive any later failure.
    try Data("prior export".utf8).write(to: output)
    try RecordingExport.write(
      meeting: meeting, directory: directory, source: "Microphone", prepared: false, to: output)
    let file = try AVAudioFile(forReading: output)
    #expect(file.length == 96000)
    #expect(file.processingFormat.channelCount == 2)
    #expect(file.processingFormat.sampleRate == 48000)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96000))
    try file.read(into: buffer)
    for channel in 0..<2 {
      let samples = buffer.floatChannelData![channel]
      #expect(samples[1000] == 0)
      #expect(abs(samples[24000] - 0.25) < 0.001)
      #expect(samples[42000] == 0)
      #expect(abs(samples[60000] + 0.5) < 0.001)
      #expect(samples[90000] == 0)
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent(a)) == original)
    let exported = try Data(contentsOf: output)
    #expect(throws: (any Error).self) {
      try RecordingExport.write(
        meeting: meeting, directory: directory, source: "System audio", prepared: false, to: output)
    }
    #expect(try Data(contentsOf: output) == exported)
    #expect(throws: (any Error).self) {
      try RecordingExport.write(
        meeting: meeting, directory: directory, source: "Microphone", prepared: false,
        to: directory.appendingPathComponent(a))
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent(a)) == original)
  }
}
@Test func preparedExportCopiesActualInputAndRejectsStalePreparation() throws {
  try fixture { root, directory in
    var meeting = Meeting.make(title: "Prepared", context: "", language: "en")
    meeting.audioTracks = [AudioTrack(id: "a", label: "Microphone", filename: "a.caf", duration: 1)]
    let passID = newID()
    meeting.preparedRecording = PreparedRecording(passID: passID, trackIDs: ["a"])
    let derived = directory.appendingPathComponent("derived/" + passID)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    let input = derived.appendingPathComponent("microphone-prepared.wav")
    try makeAudio(input, rate: 16000, channels: 1, seconds: 0.5, value: 0.2)
    #expect(
      RecordingExport.sources(meeting: meeting, directory: directory).first?.preparedAvailable
        == true)
    let output = root.appendingPathComponent("prepared.wav")
    try RecordingExport.write(
      meeting: meeting, directory: directory, source: "Microphone", prepared: true, to: output)
    #expect(try Data(contentsOf: input) == Data(contentsOf: output))
    meeting.audioTracks.append(
      AudioTrack(id: "b", label: "System audio", filename: "b.caf", duration: 1))
    #expect(
      RecordingExport.sources(meeting: meeting, directory: directory).allSatisfy {
        !$0.preparedAvailable
      })
    #expect(throws: (any Error).self) {
      try RecordingExport.write(
        meeting: meeting, directory: directory, source: "Microphone", prepared: true, to: output)
    }
    #expect(try Data(contentsOf: input) == Data(contentsOf: output))
  }
}
