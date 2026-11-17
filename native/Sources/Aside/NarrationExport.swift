import CryptoKit
import Foundation

struct NarrationExportPlan: Sendable {
  var text: String
  var voiceURL: URL
  var cacheURL: URL
  var language: String

  static func make(meeting: Meeting, voiceProfileID: String, language: String, root: URL) throws
    -> Self
  {
    guard meeting.status != "recording", meeting.status != "processing", meeting.pendingStage == nil
    else {
      throw AsideError("Finish the meeting and final transcript before exporting narration")
    }
    guard let document = meeting.document else {
      throw AsideError("Create the final written transcript before exporting narration")
    }
    let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw AsideError("There is no corrected transcript to narrate") }
    let voice: URL
    if voiceProfileID == "you" {
      voice = root.appendingPathComponent("voice-profile/reference.wav")
      guard FileManager.default.isReadableFile(atPath: voice.path) else {
        throw AsideError("Save your voice sample in Settings first")
      }
    } else {
      voice = try VoiceProfileStore(root: root).sampleURL(voiceProfileID)
    }
    let selectedLanguage = ["English", "Spanish", "auto"].contains(language) ? language : "English"
    var evidence = Data(
      ([
        LocalNarrationService.modelID, LocalNarrationService.modelRevision,
        LocalNarrationService.runtimeVersion, LocalNarrationService.conditioningVersion,
        "seed=\(LocalNarrationService.seed)", selectedLanguage, text,
      ].joined(separator: "\n")).utf8)
    evidence.append(try Data(contentsOf: voice))
    let key = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
    let cache = root.appendingPathComponent(
      "meetings/" + meeting.id + "/derived/narration/" + key + ".wav")
    return Self(text: text, voiceURL: voice, cacheURL: cache, language: selectedLanguage)
  }
}
