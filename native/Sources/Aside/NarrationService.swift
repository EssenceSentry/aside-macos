import Darwin
import Foundation

struct NarrationRuntimeStatus: Codable, Sendable {
  var ready: Bool
  var message: String
  var modelID: String
}

struct NarrationResult: Sendable {
  var outputURL: URL
  var duration: Double
  var elapsedSeconds: Double
}

/// A separate process releases MLX model memory when the export finishes. The
/// generated readout never modifies captured audio, prepared audio or voice samples.
actor LocalNarrationService {
  static let modelID = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
  static let modelRevision = "e7dd0585652209fa0d7783659aad4e8a324de11c"
  static let runtimeVersion = "0.6.4"
  static let conditioningVersion = "speaker-only-v1"
  static let seed = 42
  let runtimeRoot: URL
  private let helperURL: URL?
  private var busy = false

  /// `root` is Aside's Application Support directory, not the model directory.
  init(root: URL, helperURL: URL? = nil) {
    runtimeRoot = root.appendingPathComponent("narration", isDirectory: true)
    self.helperURL = helperURL ?? Self.bundledHelper()
  }

  func status() -> NarrationRuntimeStatus {
    let manager = FileManager.default
    let required = [
      "venv/bin/python", "models/qwen3-tts-1.7b-base-8bit/config.json",
      "models/qwen3-tts-1.7b-base-8bit/model.safetensors",
      "models/qwen3-tts-1.7b-base-8bit/speech_tokenizer/model.safetensors",
      "models/whisper-small/config.json", "models/whisper-small/weights.npz",
    ]
    let filesReady =
      helperURL != nil
      && required.allSatisfy {
        manager.fileExists(atPath: runtimeRoot.appendingPathComponent($0).path)
      }
    let installedVersion = try? String(
      contentsOf: runtimeRoot.appendingPathComponent("runtime-version"), encoding: .utf8)
    let ready = filesReady && installedVersion == Self.runtimeVersion
    return NarrationRuntimeStatus(
      ready: ready,
      message: ready
        ? "Local narration is ready"
        : filesReady
          ? "Update the local narration runtime" : "Download the local narration models first",
      modelID: Self.modelID)
  }

  func prepare(progress: (@Sendable (String) async -> Void)? = nil) async throws {
    guard !busy else { throw AsideError("Local narration is already working") }
    guard let helperURL else { throw AsideError("The narration helper is missing from this app") }
    busy = true
    defer { busy = false }
    try makePrivateDirectory(runtimeRoot)
    guard let uv = Self.uvExecutable() else {
      throw AsideError(
        "Local narration setup needs uv. Install uv, then try Download narration models again")
    }
    let python = runtimeRoot.appendingPathComponent("venv/bin/python")
    if !FileManager.default.isExecutableFile(atPath: python.path) {
      await progress?("Creating the private local narration runtime")
      _ = try await run(
        uv,
        arguments: ["venv", "--python", "3.11", runtimeRoot.appendingPathComponent("venv").path])
    }
    await progress?("Installing the local voice runtime")
    _ = try await run(
      uv,
      arguments: [
        "pip", "install", "--python", python.path, "mlx-audio==\(Self.runtimeVersion)",
        "mlx-whisper==0.4.3",
      ])
    _ = try await run(
      python, arguments: [helperURL.path, "prepare", "--root", runtimeRoot.path], progress: progress
    )
    let versionFile = runtimeRoot.appendingPathComponent("runtime-version")
    try Self.runtimeVersion.write(to: versionFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: versionFile.path)
    guard status().ready else { throw AsideError("The local narration setup is incomplete") }
  }

  func synthesize(
    text: String, voiceSampleURL: URL, outputURL: URL, language: String? = nil,
    progress: (@Sendable (String) async -> Void)? = nil
  ) async throws -> NarrationResult {
    guard !busy else { throw AsideError("Local narration is already working") }
    guard status().ready, let helperURL else {
      throw AsideError("Download the local narration models before exporting narrated audio")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AsideError("There is no corrected transcript to narrate")
    }
    guard
      voiceSampleURL.standardizedFileURL.resolvingSymlinksInPath()
        != outputURL.standardizedFileURL.resolvingSymlinksInPath()
    else { throw AsideError("Choose an export destination other than the saved voice sample") }
    busy = true
    defer { busy = false }
    try makePrivateDirectory(runtimeRoot)
    let requestURL = runtimeRoot.appendingPathComponent("request-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: requestURL) }
    let request: [String: Any] = [
      "text": text, "voiceSampleURL": voiceSampleURL.path, "outputURL": outputURL.path,
      "language": language ?? "English", "speakerOnly": true, "seed": Self.seed,
    ]
    // Write private before adding content; the corrected transcript is not a CLI argument.
    FileManager.default.createFile(
      atPath: requestURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try JSONSerialization.data(withJSONObject: request).write(to: requestURL)
    let result = try await run(
      runtimeRoot.appendingPathComponent("venv/bin/python"),
      arguments: [
        helperURL.path, "synthesize", "--root", runtimeRoot.path, "--request", requestURL.path,
      ],
      offline: true, progress: progress)
    guard let duration = result["duration"] as? Double,
      let elapsed = result["elapsedSeconds"] as? Double,
      duration.isFinite, duration > 0,
      FileManager.default.fileExists(atPath: outputURL.path)
    else { throw AsideError("The local voice model did not produce a valid audio export") }
    return NarrationResult(outputURL: outputURL, duration: duration, elapsedSeconds: elapsed)
  }

  private func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func bundledHelper() -> URL? {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("narration_backend.py")
    if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    // Developer/test executable fallback; release bundles copy the same source helper.
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("scripts/narration_backend.py")
    return FileManager.default.fileExists(atPath: source.path) ? source : nil
  }

  private static func uvExecutable() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates =
      [
        home.appendingPathComponent(".local/bin/uv").path,
        "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
      ]
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/uv" }
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map {
      URL(fileURLWithPath: $0)
    }
  }

  private func run(
    _ executable: URL, arguments: [String], offline: Bool = false,
    progress: (@Sendable (String) async -> Void)? = nil
  ) async throws -> [String: Any] {
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
    environment["DO_NOT_TRACK"] = "1"
    environment["PYTHONUNBUFFERED"] = "1"
    if offline {
      environment["HF_HUB_OFFLINE"] = "1"
      environment["TRANSFORMERS_OFFLINE"] = "1"
    }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    // Model libraries may print their recognized reference to stderr. Never forward
    // that into app logs; structured progress/errors arrive through stdout instead.
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    do {
      let result = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<[String: Any], Error>) in
          // FileHandle.AsyncBytes can serialize reads from unrelated pipes. A
          // quiet model process must not hold up cancellation or completion of
          // another process. Drain each pipe on its own blocking I/O queue.
          let queue = DispatchQueue(label: "aside.narration.pipe." + UUID().uuidString)
          queue.async {
            var result: [String: Any] = [:]
            var failure: String?
            var pending = Data()
            var progressTask: Task<Void, Never>?
            func receive(_ line: Data) {
              guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
              else { return }
              switch event["event"] as? String {
              case "progress":
                if let message = event["message"] as? String {
                  let preceding = progressTask
                  progressTask = Task<Void, Never> {
                    await preceding?.value
                    await progress?(message)
                  }
                }
              case "result": result = event
              case "error": failure = event["message"] as? String
              default: break
              }
            }
            let completion: Result<[String: Any], Error>
            do {
              let descriptor = pipe.fileHandleForReading.fileDescriptor
              var buffer = [UInt8](repeating: 0, count: 65536)
              while true {
                // Foundation can fill the requested buffer before returning
                // from a pipe. POSIX read delivers each available progress
                // message while the model is still generating audio.
                let count = buffer.withUnsafeMutableBytes {
                  Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                  let code = errno
                  if code == EINTR { continue }
                  throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                if count == 0 { break }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                  receive(Data(pending[..<newline]))
                  pending.removeSubrange(...newline)
                }
              }
              if !pending.isEmpty { receive(pending) }
              process.waitUntilExit()
              if process.terminationStatus != 0 {
                throw AsideError(
                  failure
                    ?? "The local narration process failed (\(process.terminationStatus)). Try preparing its runtime again"
                )
              }
              completion = .success(result)
            } catch {
              if process.isRunning { process.terminate() }
              // Returning from cancellation means the child has exited and its
              // Python finally blocks have finished, not just received SIGTERM.
              process.waitUntilExit()
              completion = .failure(error)
            }
            try? pipe.fileHandleForReading.close()
            let preceding = progressTask
            Task {
              await preceding?.value
              continuation.resume(with: completion)
            }
          }
        }
      } onCancel: {
        if process.isRunning { process.terminate() }
      }
      try Task.checkCancellation()
      return result
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}
