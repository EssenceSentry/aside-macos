import CryptoKit
import Foundation

struct MemoryProvenance: Codable, Sendable {
  var provider: String
  var path: String
  var modifiedAt: String
  var sha256: String
}
struct MemoryNote: Sendable {
  var source: MemoryProvenance
  var text: String
}
struct MemoryFragment: Encodable, Sendable {
  var provider: String
  var path: String
  var modifiedAt: String
  var part: Int
  var text: String
}
struct MemoryCorpus: Sendable {
  var notes: [MemoryNote]
  var manifest: [MemoryProvenance] { notes.map(\.source) }
  var description: String {
    ["Claude", "Codex"].map { provider in
      "\(notes.filter { $0.source.provider == provider }.count) \(provider) notes"
    }.joined(separator: " + ")
  }
  func batches() throws -> [[MemoryFragment]] {
    let encoder = JSONEncoder()
    var batches: [[MemoryFragment]] = []
    var current: [MemoryFragment] = []
    var bytes = 0
    for note in notes {
      var text = note.text[...]
      var part = 0
      while !text.isEmpty {
        let end =
          text.index(text.startIndex, offsetBy: 12_000, limitedBy: text.endIndex) ?? text.endIndex
        part += 1
        let fragment = MemoryFragment(
          provider: note.source.provider, path: note.source.path,
          modifiedAt: note.source.modifiedAt, part: part, text: String(text[..<end]))
        text = text[end...]
        let size = try encoder.encode(fragment).count + 2
        if bytes + size > 90_000, !current.isEmpty {
          batches.append(current)
          current = []
          bytes = 0
        }
        current.append(fragment)
        bytes += size
      }
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }
}

enum MemoryReader {
  /// Reads memory notes, never provider settings, credentials or full session logs.
  static func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> MemoryCorpus
  {
    let fm = FileManager.default
    let modern = home.appendingPathComponent(".codex/memories_v2")
    let codex =
      fm.fileExists(atPath: modern.path) ? modern : home.appendingPathComponent(".codex/memories")
    let projects = home.appendingPathComponent(".claude/projects")
    var roots: [(String, URL)] = [("Codex", codex)]
    if fm.fileExists(atPath: projects.path) {
      roots += try fm.contentsOfDirectory(
        at: projects, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
      )
      .filter {
        let value = try $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        return value.isSymbolicLink != true && value.isDirectory == true
      }
      .map { ("Claude", $0.appendingPathComponent("memory")) }
    }
    var notes: [MemoryNote] = []
    var total = 0
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    for (provider, root) in roots {
      let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
      guard
        let files = fm.enumerator(
          at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
      else { continue }
      for case let url as URL in files {
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true {
          files.skipDescendants()
          continue
        }
        guard values.isRegularFile == true, url.pathExtension.lowercased() == "md",
          !["raw_memories.md", "instructions.md"].contains(url.lastPathComponent.lowercased()),
          url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonical)
        else { continue }
        let size = values.fileSize ?? 0
        guard size <= 1_000_000, total + size <= 4_000_000 else {
          throw AsideError(
            "The memory notes exceed this consolidation's size limit. Your existing brief was kept."
          )
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
          throw AsideError("A memory note is not readable UTF-8. Your existing brief was kept.")
        }
        total += data.count
        let path = "~" + url.path.dropFirst(home.path.count)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        notes.append(
          MemoryNote(
            source: MemoryProvenance(
              provider: provider, path: path,
              modifiedAt: ISO8601DateFormatter().string(
                from: values.contentModificationDate ?? .distantPast), sha256: hash),
            text: redact(text)))
      }
    }
    guard
      ["Claude", "Codex"].allSatisfy({ provider in notes.contains { $0.source.provider == provider }
      })
    else {
      throw AsideError(
        "Both Claude and Codex local memory notes are needed. Your existing brief was kept.")
    }
    return MemoryCorpus(notes: notes.sorted { $0.source.path < $1.source.path })
  }
  static func redact(_ text: String) -> String {
    var result = text
    for pattern in [
      #"(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#,
      #"\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b"#,
      #"(?im)^\s*(?:api[_ -]?key|password|access[_ -]?token|secret[_ -]?key)\s*[:=].+$"#,
    ] {
      result = result.replacingOccurrences(
        of: pattern, with: "[REDACTED CREDENTIAL]", options: .regularExpression)
    }
    return result
  }
}
