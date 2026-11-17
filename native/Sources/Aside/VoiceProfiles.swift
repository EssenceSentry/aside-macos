import AsideAudio
import AsideWhisper
import Foundation

struct VoiceProfileSample: Codable, Sendable, Equatable {
  var id: String
  var filename: String
  var duration: Double
  var createdAt: String
  var meetingID: String? = nil
  var speaker: String? = nil
}
struct VoiceProfile: Codable, Sendable, Equatable {
  var id: String
  var name: String
  var enabled: Bool
  var createdAt: String
  var updatedAt: String
  var samples: [VoiceProfileSample]
}
struct VoiceProfileStore: Sendable {
  let root: URL
  private var directory: URL { root.appendingPathComponent("voice-profiles") }
  private var index: URL { directory.appendingPathComponent("profiles.json") }

  func profiles() throws -> [VoiceProfile] {
    guard FileManager.default.fileExists(atPath: index.path) else { return [] }
    return try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: index))
  }
  private func write(_ profiles: [VoiceProfile]) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try encoder.encode(profiles).write(to: index, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
  }
  @discardableResult func save(
    _ samples: [Float], name: String, meetingID: String? = nil, speaker: String? = nil
  ) throws -> VoiceProfile {
    let name = try Self.validatedName(name)
    guard samples.count >= 16000 * 8, samples.count <= 16000 * 120,
      samples.allSatisfy(\.isFinite)
    else {
      throw AsideError("Use 8–120 seconds of solo speech for a voice reference")
    }
    var profiles = try profiles()
    let existing = profiles.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    var profile =
      existing.map { profiles[$0] }
      ?? VoiceProfile(
        id: newID(), name: name, enabled: true, createdAt: timestamp(), updatedAt: timestamp(),
        samples: [])
    let folder = directory.appendingPathComponent(profile.id)
    guard UUID(uuidString: profile.id) != nil else { throw AsideError("Invalid voice profile ID") }
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let sampleID = newID()
    let filename = sampleID + ".wav"
    try AudioPreparationModel.write(samples, to: folder.appendingPathComponent(filename))
    profile.samples.append(
      VoiceProfileSample(
        id: sampleID, filename: filename,
        duration: Double(samples.count) / 16000, createdAt: timestamp(), meetingID: meetingID,
        speaker: speaker))
    profile.updatedAt = timestamp()
    profile.enabled = true
    if let existing { profiles[existing] = profile } else { profiles.append(profile) }
    do {
      try write(profiles)
    } catch {
      // A failed index write must not leave an unlisted voice recording behind.
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(filename))
      throw error
    }
    return profile
  }
  private static func validatedName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AsideError("Enter the person's name") }
    guard !name.contains(" + "), !name.contains(" · ") else {
      throw AsideError("Use a name without the speaker separators ‘ + ’ or ‘ · ’")
    }
    return name
  }
  @discardableResult func rename(_ id: String, name: String) throws -> VoiceProfile {
    let name = try Self.validatedName(name)
    var profiles = try profiles()
    guard let i = profiles.firstIndex(where: { $0.id == id }) else {
      throw AsideError("Voice profile not found")
    }
    guard
      !profiles.contains(where: {
        $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
      })
    else { throw AsideError("A voice profile with that name already exists") }
    profiles[i].name = name
    profiles[i].updatedAt = timestamp()
    try write(profiles)
    return profiles[i]
  }
  func setEnabled(_ id: String, enabled: Bool) throws {
    var profiles = try profiles()
    guard let i = profiles.firstIndex(where: { $0.id == id }) else {
      throw AsideError("Voice profile not found")
    }
    profiles[i].enabled = enabled
    profiles[i].updatedAt = timestamp()
    try write(profiles)
  }
  /// Resolve an original saved recording without decoding on the UI actor.
  /// Playback and other local audio consumers share the same safe fallback.
  func sampleURL(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil,
      let profile = try profiles().first(where: { $0.id == id })
    else { throw AsideError("Voice profile not found") }
    for sample in profile.samples.reversed() {
      guard let url = sampleLocation(profileID: id, filename: sample.filename),
        FileManager.default.isReadableFile(atPath: url.path),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      return url
    }
    throw AsideError("No readable recording remains for this voice profile")
  }
  private func sampleLocation(profileID: String, filename: String) -> URL? {
    guard UUID(uuidString: profileID) != nil,
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      filename.hasSuffix(".wav")
    else { return nil }
    return directory.appendingPathComponent(profileID).appendingPathComponent(filename)
  }
  func references() throws -> [SpeakerReference] {
    var references: [SpeakerReference] = []
    for profile in try profiles() where profile.enabled && UUID(uuidString: profile.id) != nil {
      var samples: [Float] = []
      // Keep complete originals. Three recent usable, centered excerpts bound
      // repeated live inference to one minute per person, regardless of imports.
      var loaded = 0
      for sample in profile.samples.reversed() where loaded < 3 {
        guard let url = sampleLocation(profileID: profile.id, filename: sample.filename),
          let audio = try? AudioPreparationModel.load(url)
        else { continue }
        guard audio.count >= 16000 * 8, audio.allSatisfy(\.isFinite) else { continue }
        let count = min(audio.count, 16000 * 20)
        let start = (audio.count - count) / 2
        if !samples.isEmpty { samples += [Float](repeating: 0, count: 4000) }
        samples += audio[start..<(start + count)]
        loaded += 1
      }
      if samples.count >= 16000 * 8 {
        references.append(SpeakerReference(speaker: profile.name, samples: samples))
      }
    }
    return references
  }
}

/// Extract an enrolled speaker from the saved acoustic turns, using original
/// audio. Recognition text and inferred document names never generate a sample.
enum VoiceProfileAudio {
  static func sample(meeting: Meeting, speaker: String, directory: URL) throws -> [Float] {
    guard !Set(meeting.audioTracks.map(\.label)).contains(speaker),
      speaker != "Mixed speakers", !speaker.contains(" + "), !speaker.hasSuffix("Unknown speaker")
    else {
      throw AsideError("Identify individual voices before saving a participant reference")
    }
    var candidates: [(source: String, regions: [SpeechRegion])] = []
    let sources = Set(meeting.audioTracks.map(\.label))
    for source in sources {
      let local =
        speaker.hasPrefix(source + " · ") ? String(speaker.dropFirst(source.count + 3)) : speaker
      let relevant =
        sources.count == 1 || speaker == "You" || speaker.hasPrefix(source + " · ")
        || !speaker.contains(" · ")
      guard relevant else { continue }
      let analysisURL = meeting.preparedRecording.map {
        directory.appendingPathComponent(
          "derived/" + $0.passID + "/" + RecordingExport.sourceName(source) + "-speakers.json")
      }
      if let analysisURL, let data = try? Data(contentsOf: analysisURL),
        let analysis = try? JSONDecoder().decode(SpeakerAnalysis.self, from: data)
      {
        let base = meeting.preparedRecording?.timelineOffset ?? 0
        let own = analysis.turns.filter { $0.speaker == local }.map {
          SpeechRegion(start: base + $0.start, end: base + $0.end)
        }
        let other = analysis.turns.filter { $0.speaker != local }.map {
          SpeechRegion(start: base + $0.start, end: base + $0.end)
        }
        candidates.append((source, clean(own, excluding: other)))
      } else if sources.count == 1 || speaker.hasPrefix(source + " · ")
        || (speaker == "You" && source == "Microphone")
      {
        let own = meeting.segments.filter { !$0.isNote && $0.speaker == speaker }
          .map { SpeechRegion(start: $0.start, end: $0.end) }
        let other = meeting.segments.filter { !$0.isNote && $0.speaker != speaker }
          .map { SpeechRegion(start: $0.start, end: $0.end) }
        candidates.append((source, clean(own, excluding: other)))
      }
    }
    if speaker == "You", let mic = candidates.first(where: { $0.source == "Microphone" }),
      duration(mic.regions) >= 8
    {
      candidates = [mic]
    }
    guard let selected = candidates.max(by: { duration($0.regions) < duration($1.regions) }),
      duration(selected.regions) >= 8
    else {
      throw AsideError(
        "There isn't eight seconds of separate speech for this speaker yet. Identify voices first, or import a solo recording in Settings."
      )
    }
    let chunks = meeting.audioTracks.filter { $0.label == selected.source }.map {
      CapturedChunk(
        track: $0, url: directory.appendingPathComponent($0.filename),
        offset: ChunkWriter.offset(for: $0.filename), speaker: selected.source)
    }
    var remaining = 30.0
    var chosen: [SpeechRegion] = []
    for region in selected.regions.sorted(by: { $0.end - $0.start > $1.end - $1.start })
    where remaining > 0 {
      let seconds = min(remaining, region.end - region.start)
      chosen.append(SpeechRegion(start: region.start, end: region.start + seconds))
      remaining -= seconds
    }
    return try extract(chunks: chunks, regions: chosen.sorted { $0.start < $1.start })
  }
  private static func duration(_ regions: [SpeechRegion]) -> Double {
    regions.reduce(0) { $0 + $1.end - $1.start }
  }
  static func clean(_ own: [SpeechRegion], excluding other: [SpeechRegion]) -> [SpeechRegion] {
    let ranges = SpeakerReviewAttribution.merged(
      own.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        .map { $0.start..<$0.end })
    var output: [SpeechRegion] = []
    for range in ranges {
      var pieces = [range]
      for obstacle in other
      where obstacle.start.isFinite && obstacle.end.isFinite && obstacle.end > obstacle.start {
        pieces = pieces.flatMap { part -> [Range<Double>] in
          guard obstacle.start < part.upperBound && obstacle.end > part.lowerBound else {
            return [part]
          }
          var rest: [Range<Double>] = []
          if part.lowerBound < obstacle.start {
            rest.append(part.lowerBound..<min(obstacle.start, part.upperBound))
          }
          if obstacle.end < part.upperBound {
            rest.append(max(obstacle.end, part.lowerBound)..<part.upperBound)
          }
          return rest
        }
      }
      output += pieces.compactMap { part in
        let start = part.lowerBound + 0.12
        let end = part.upperBound - 0.12
        return end - start >= 0.6 ? SpeechRegion(start: start, end: end) : nil
      }
    }
    return output
  }
  static func extract(chunks: [CapturedChunk], regions: [SpeechRegion]) throws -> [Float] {
    var cache: [String: [Float]] = [:]
    var output: [Float] = []
    for region in regions {
      guard region.start.isFinite, region.end.isFinite, region.start >= 0,
        region.end > region.start, region.end - region.start <= 120
      else { throw AsideError("Invalid voice reference audio interval") }
      let count = Int(((region.end - region.start) * 16000).rounded())
      guard count > 0 else { continue }
      var clip = [Float](repeating: 0, count: count)
      var covered: [Range<Double>] = []
      for chunk in chunks
      where chunk.offset < region.end && chunk.offset + chunk.track.duration > region.start {
        let audio: [Float]
        if let cached = cache[chunk.track.id] {
          audio = cached
        } else {
          audio = try AudioPreparationModel.load(chunk.url)
          cache[chunk.track.id] = audio
        }
        let shift = Int(((chunk.offset - region.start) * 16000).rounded())
        let skip = max(0, -shift)
        let lower = max(0, shift)
        let amount = min(audio.count - skip, clip.count - lower)
        if amount > 0 {
          clip.replaceSubrange(lower..<(lower + amount), with: audio[skip..<(skip + amount)])
          covered.append(Double(lower)..<Double(lower + amount))
        }
      }
      let available = SpeakerReviewAttribution.merged(covered).reduce(0) {
        $0 + $1.upperBound - $1.lowerBound
      }
      guard available == Double(count) else {
        throw AsideError(
          "The original recording has a gap in this voice sample. Select another turn or import a solo recording."
        )
      }
      if !output.isEmpty { output += [Float](repeating: 0, count: 4000) }
      output += clip
    }
    return output
  }
}
