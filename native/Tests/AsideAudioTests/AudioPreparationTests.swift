import AsideAudio
import Foundation
import Testing

@Test func compressesOnlyUnvoicedGapsAndMapsBackToOriginalSpeech() {
  let rate = 16_000
  let samples =
    [Float](repeating: 0, count: rate) + [Float](repeating: 0.05, count: rate)
    + [Float](repeating: 0, count: 3 * rate) + [Float](repeating: 0.08, count: rate)
    + [Float](repeating: 0, count: rate)
  let result = AudioPreparationModel.render(
    samples,
    regions: [.init(start: 1, end: 2), .init(start: 5, end: 6)],
    profile: .init(retainedPause: 0.4, speechPadding: 0.2, normalize: false))
  #expect(abs(result.metrics.preparedSeconds - 3.2) < 0.001)
  #expect(result.samples.filter { $0 == 0.05 }.count == rate)
  #expect(result.samples.filter { $0 == 0.08 }.count == rate)
  #expect(abs(result.originalTime(0.2) - 1) < 0.001)
  #expect(abs(result.originalTime(2.0) - 5) < 0.001)
  #expect(samples.count == 7 * rate)
}

@Test func noDetectedSpeechNeverErasesPotentiallyQuietOrAccentedAudio() {
  let samples = [Float](repeating: 0.00005, count: 32000)
  let result = AudioPreparationModel.render(samples, regions: [], profile: .init())
  #expect(result.samples == samples)
  #expect(result.metrics.preparedSeconds == 2)
  #expect(result.originalTime(1) == 1)
}

@Test func normalizationIsBoundedAndNeverIntroducesClipping() {
  let samples: [Float] = [12, -12, 0.01, -0.01]
  let result = AudioPreparationModel.render(
    samples,
    regions: [.init(start: 0, end: 1)], profile: .init(normalize: true, shortenSilences: false))
  #expect(result.samples.allSatisfy { abs($0) <= 0.97 })
  #expect(result.metrics.gain <= 4)
  #expect(result.samples.count == samples.count)
}

@Test func overlappingPaddedRegionsDoNotDuplicateSpeechOrShrinkShortPauses() {
  let samples = [Float](repeating: 0.1, count: 48000)
  let result = AudioPreparationModel.render(
    samples,
    regions: [.init(start: 0, end: 1.2), .init(start: 1.3, end: 3)],
    profile: .init(normalize: false))
  #expect(result.samples == samples)
  #expect(result.timeMap.count == 1)
}

@Test func audioRoundTripFinalizesAPlayableWaveFile() throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".wav")
  defer { try? FileManager.default.removeItem(at: path) }
  let samples = (0..<32000).map { Float(sin(Double($0) * 0.1)) * 0.05 }
  try AudioPreparationModel.write(samples, to: path)
  let restored = try AudioPreparationModel.load(path)
  #expect(restored.count == samples.count)
  #expect(zip(samples, restored).allSatisfy { abs($0 - $1) < 0.00001 })
}
@Test func experimentalFillerMaskNeverChangesNeighboringSpeech() {
  let samples = [Float](repeating: 0.1, count: 16000)
  let output = AudioPreparationModel.maskFillers(samples, regions: [.init(start: 0.4, end: 0.6)])
  #expect(Array(output[..<6400]) == Array(samples[..<6400]))
  #expect(Array(output[9600...]) == Array(samples[9600...]))
  #expect(output[8000] == 0)
  #expect(samples[8000] == 0.1)
}
