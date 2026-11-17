import AsideAudio
import FluidAudio
import Foundation

struct VariantResult: Codable {
  var name: String
  var profile: PreparationProfile
  var metrics: PreparationMetrics
  var elapsedSeconds: Double
  var transcript: String
  var confidence: Float
  var fillerDetections: Int? = nil
}
struct BenchmarkResult: Codable {
  var input: String
  var speechModel: String
  var activityModel: String
  var createdAt: String
  var referenceAvailable: Bool
  var startSeconds: Double
  var endSeconds: Double
  var variants: [VariantResult]
}

@main
struct AudioBenchmark {
  static func main() async throws {
    let arguments = CommandLine.arguments
    func value(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }
    guard let input = value("--input"), let root = value("--model-root"),
      let destination = value("--output")
    else {
      print(
        "Usage: AsideAudioBench --input recording.wav --model-root '/path/to/Aside' --output /private/evaluation [--download-vad]"
      )
      return
    }
    let output = URL(fileURLWithPath: destination, isDirectory: true)
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let original = try AudioPreparationModel.load(URL(fileURLWithPath: input))
    let from = max(0, Double(value("--from") ?? "0") ?? 0)
    let to = min(
      Double(original.count) / 16000, Double(value("--to") ?? "") ?? Double(original.count) / 16000)
    guard to > from else { throw PreparationError.invalidSamples }
    let samples = Array(original[Int(from * 16000)..<Int(to * 16000)])
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let ultra = value("--version") == "ultra"
    let version: AsrModelVersion = ultra ? .ultra : .v3
    let modelName = ultra ? "Parakeet Ultra" : "NVIDIA Parakeet TDT 0.6B v3"
    let modelDirectory = rootURL.appendingPathComponent(
      ultra ? "models/parakeet-ultra" : "models/parakeet-v3")
    ModelHub.offlineMode = !arguments.contains("--download-model")
    let models: AsrModels
    if arguments.contains("--download-model") {
      models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: version)
    } else {
      models = try await AsrModels.load(from: modelDirectory, version: version)
    }
    ModelHub.offlineMode = true
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let preparer = AudioPreparationModel(
      directory: rootURL.appendingPathComponent("models/audio-preparation"))
    let variants: [(String, PreparationProfile)] = [
      ("long-context-original", .init(normalize: false, shortenSilences: false)),
      ("long-context-normalized", .init(normalize: true, shortenSilences: false)),
      ("pauses-350ms", .init(normalize: false)),
      ("pauses-350ms-normalized", .init(normalize: true)),
      ("pauses-600ms-normalized", .init(retainedPause: 0.6, normalize: true)),
      ("vad-threshold-040", .init(threshold: 0.4, normalize: true)),
      ("vad-threshold-060", .init(threshold: 0.6, normalize: true)),
    ]
    var results: [VariantResult] = []
    var fillerSpans: [SpeechRegion] = []
    for (name, profile) in variants {
      let start = Date()
      let prepared = try await preparer.prepare(
        samples, profile: profile, allowDownload: arguments.contains("--download-vad"))
      try AudioPreparationModel.write(
        prepared.samples, to: output.appendingPathComponent(name + ".wav"))
      var state = try TdtDecoderState()
      let result = try await asr.transcribe(prepared.samples, decoderState: &state)
      if name == "long-context-original" {
        fillerSpans = AudioPreparationModel.fillerRegions(
          from: buildWordTimings(from: result.tokenTimings ?? []))
      }
      results.append(
        VariantResult(
          name: name, profile: profile, metrics: prepared.metrics,
          elapsedSeconds: Date().timeIntervalSince(start), transcript: result.text,
          confidence: Float(result.confidence)))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let value = BenchmarkResult(
        input: input, speechModel: modelName,
        activityModel: "Silero VAD v6.2.1 Core ML",
        createdAt: ISO8601DateFormatter().string(from: Date()), referenceAvailable: false,
        startSeconds: from, endSeconds: to,
        variants: results)
      let path = output.appendingPathComponent("results.json")
      try encoder.encode(value).write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      print(
        String(
          format: "%@: %.2f → %.2f sec; gain %.2f; %.2f sec processing", name,
          prepared.metrics.originalSeconds, prepared.metrics.preparedSeconds, prepared.metrics.gain,
          results.last!.elapsedSeconds))
    }
    for compress in [false, true] {
      let name = compress ? "pauses-filler-masked-experimental" : "filler-masked-experimental"
      let profile = PreparationProfile(normalize: false, shortenSilences: compress)
      let start = Date()
      let masked = AudioPreparationModel.maskFillers(samples, regions: fillerSpans)
      let prepared = try await preparer.prepare(
        masked, profile: profile, allowDownload: arguments.contains("--download-vad"))
      try AudioPreparationModel.write(
        prepared.samples, to: output.appendingPathComponent(name + ".wav"))
      var state = try TdtDecoderState()
      let result = try await asr.transcribe(prepared.samples, decoderState: &state)
      results.append(
        VariantResult(
          name: name, profile: profile, metrics: prepared.metrics,
          elapsedSeconds: Date().timeIntervalSince(start), transcript: result.text,
          confidence: Float(result.confidence), fillerDetections: fillerSpans.count))
      print("\(name): \(fillerSpans.count) model-detected fillers masked")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let complete = BenchmarkResult(
      input: input, speechModel: modelName,
      activityModel: "Silero VAD v6.2.1 Core ML",
      createdAt: ISO8601DateFormatter().string(from: Date()), referenceAvailable: false,
      startSeconds: from, endSeconds: to, variants: results)
    try encoder.encode(complete).write(
      to: output.appendingPathComponent("results.json"), options: .atomic)
    print("Saved private comparison: \(output.appendingPathComponent("results.json").path)")
    print("No accuracy winner is selected without the user's reference transcript.")
  }
}
