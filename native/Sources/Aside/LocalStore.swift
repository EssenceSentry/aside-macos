import Foundation

/// Atomic snapshots; raw audio chunks are independently committed and discovered on recovery.
final class LocalStore {
  let root: URL
  private let encoder: JSONEncoder
  private let trashItem: (URL) throws -> Void
  init(root: URL? = nil, trashItem: ((URL) throws -> Void)? = nil) throws {
    self.trashItem =
      trashItem ?? { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }
    let override = ProcessInfo.processInfo.environment["ASIDE_DATA_DIR"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    self.root =
      root ?? override
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Aside", isDirectory: true)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for path in [
      self.root, self.root.appendingPathComponent("meetings"),
      self.root.appendingPathComponent("documents"),
    ] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
  func write<T: Encodable>(_ value: T, to url: URL) throws {
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  func meetingDirectory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw AsideError("Invalid meeting ID") }
    let url = root.appendingPathComponent("meetings/\(id)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
  func save(_ meeting: Meeting) throws {
    try write(meeting, to: meetingDirectory(meeting.id).appendingPathComponent("meeting.json"))
  }
  /// Move the complete owned bundle, including recordings and derivatives, to recoverable Trash.
  func trashMeeting(_ id: String) throws {
    guard UUID(uuidString: id) != nil else { throw AsideError("Invalid meeting ID") }
    let directory = root.appendingPathComponent("meetings/\(id)", isDirectory: true)
    let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true else {
      throw AsideError("The meeting folder is not a local meeting bundle")
    }
    let meeting = try read(Meeting.self, from: directory.appendingPathComponent("meeting.json"))
    guard meeting.id == id else { throw AsideError("The meeting folder identity does not match") }
    try trashItem(directory)
  }
  func meetings() throws -> [Meeting] {
    let dirs = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("meetings"), includingPropertiesForKeys: nil)
    return try dirs.filter {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("meeting.json").path)
    }.map {
      var meeting = try read(Meeting.self, from: $0.appendingPathComponent("meeting.json"))
      if ["recording", "processing"].contains(meeting.status) {
        meeting.status = "interrupted"
        if meeting.pendingStage == nil, !meeting.audioTracks.isEmpty {
          meeting.pendingStage = meeting.document == nil ? .recognition : .polish
        }
        meeting.updatedAt = timestamp()
        try save(meeting)
      }
      let beforeNames = meeting
      TranscriptDocument.refreshSpeakerNames(&meeting)
      meeting.applySuggestedTitle()
      if meeting != beforeNames {
        meeting.updatedAt = timestamp()
        try save(meeting)
      }
      return meeting
    }.sorted { $0.createdAt > $1.createdAt }
  }
  func saveSettings(_ settings: Settings) throws {
    try write(settings, to: root.appendingPathComponent("settings.json"))
  }
  func loadSettings() throws -> Settings {
    let url = root.appendingPathComponent("settings.json")
    var settings =
      FileManager.default.fileExists(atPath: url.path)
      ? try read(Settings.self, from: url) : Settings()
    let brief = root.appendingPathComponent("work-context.md")
    if FileManager.default.fileExists(atPath: brief.path) {
      settings.workContext = String(try String(contentsOf: brief, encoding: .utf8).prefix(16_000))
    }
    return settings
  }
  func saveWorkContext(_ text: String) throws {
    let path = root.appendingPathComponent("work-context.md")
    if let previous = try? String(contentsOf: path, encoding: .utf8), !previous.isEmpty,
      previous != text
    {
      let directory = root.appendingPathComponent("work-context-history")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let snapshot = directory.appendingPathComponent(newID() + ".md")
      try previous.write(to: snapshot, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
    }
    try text.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }

  func saveGlossary(_ entries: [GlossaryEntry]) throws {
    try write(entries, to: root.appendingPathComponent("glossary.json"))
  }
  func loadGlossary() throws -> [GlossaryEntry] {
    let url = root.appendingPathComponent("glossary.json")
    return FileManager.default.fileExists(atPath: url.path)
      ? try read([GlossaryEntry].self, from: url) : []
  }
  func documentDirectory(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else { throw AsideError("Invalid document ID") }
    let url = root.appendingPathComponent("documents/\(id)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
  func indexedDocuments() throws -> [IndexedDocument] {
    try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("documents"), includingPropertiesForKeys: nil
    ).compactMap {
      let path = $0.appendingPathComponent("index.json")
      return FileManager.default.fileExists(atPath: path.path)
        ? try read(IndexedDocument.self, from: path) : nil
    }
  }
  func documentURL(_ id: String) throws -> URL? {
    let dir = try documentDirectory(id)
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("source.") }
  }
}
