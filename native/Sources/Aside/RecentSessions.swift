import Foundation
import SQLite3

/// Actual archived conversation turns, separate from long-lived memory notes.
struct RecentSessionTurn: Sendable {
  var provider: String
  var sessionID: String
  var title: String
  var project: String
  var role: String
  var date: Date
  var sequence: Int
  var text: String
}

struct RecentSessionContext: Sendable {
  var passages: [RetrievedPassage] = []
  var syncedAt: String? = nil
  var available = true
  var description: String {
    available
      ? "Actual Claude and Codex conversation turns in the rolling previous 96 hours; latest archive sync: \(syncedAt ?? "unknown"). \(passages.count) matching excerpts."
      : "The local session archive is unavailable. No recent-session evidence was supplied."
  }
}

protocol RecentSessionProviding: Sendable {
  func retrieve(query: String, now: Date) async -> RecentSessionContext
}

struct RecentSessionPaths: Sendable {
  var database: URL
  var vault: URL

  static func local(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> RecentSessionPaths
  {
    // ax's public local configuration; read only the two path settings.
    let configURL =
      ProcessInfo.processInfo.environment["AX_CONFIG"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
      } ?? home.appendingPathComponent(".config/ax/config.toml")
    let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    var section = ""
    var paths: [String: String] = [:]
    for raw in config.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        section = line
        continue
      }
      guard section == "[paths]", let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard ["data", "vault"].contains(key) else { continue }
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""),
        let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
      {
        paths[key] = decoded
      } else if value.hasPrefix("'"), value.hasSuffix("'") {
        paths[key] = String(value.dropFirst().dropLast())
      }
    }
    func path(_ value: String) -> URL {
      value.hasPrefix("~/")
        ? home.appendingPathComponent(String(value.dropFirst(2))) : URL(fileURLWithPath: value)
    }
    return RecentSessionPaths(
      database: path(paths["data"] ?? home.appendingPathComponent(".local/share/ax").path)
        .appendingPathComponent("ax.db"),
      vault: path(paths["vault"] ?? home.appendingPathComponent("Vaults/agents").path))
  }
}

enum RecentSessionReader {
  static let window: TimeInterval = 4 * 24 * 60 * 60
  static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  private static func rows(_ database: URL, sql: String, parameters: [String] = []) throws
    -> [[String]]
  {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      if let db { sqlite3_close(db) }
      throw AsideError("The local ax session index is unavailable.")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 150)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw AsideError("The local ax session index has an unsupported schema.")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in parameters.enumerated() {
      sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
    }
    var result: [[String]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { return result }
      guard step == SQLITE_ROW else { throw AsideError("The local session index is busy.") }
      result.append(
        (0..<sqlite3_column_count(statement)).map { column in
          sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
    }
  }

  static func load(paths: RecentSessionPaths, now: Date = Date()) throws -> [RecentSessionTurn] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let rows = try rows(
      paths.database,
      sql: """
        SELECT s.provider, s.session_id, COALESCE(s.title,''), COALESCE(s.project,''),
               m.role, m.ts, m.seq, m.text
        FROM messages m JOIN sessions s ON s.key = m.session_key
        WHERE s.kind = 'main' AND s.excluded = 0 AND s.provider IN ('claude','codex')
          AND m.role IN ('user','assistant')
          AND julianday(m.ts) >= julianday(?) AND julianday(m.ts) <= julianday(?)
        ORDER BY m.ts DESC, s.key, m.seq
        """,
      parameters: [
        formatter.string(from: now.addingTimeInterval(-window)), formatter.string(from: now),
      ])
    return rows.compactMap { row in
      guard UUID(uuidString: row[1]) != nil, let date = date(row[5]),
        date >= now.addingTimeInterval(-window), date <= now,
        !row[7].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return RecentSessionTurn(
        provider: row[0], sessionID: row[1], title: row[2], project: row[3], role: row[4],
        date: date, sequence: Int(row[6]) ?? 0, text: MemoryReader.redact(row[7]))
    }
  }

  static func lastSync(paths: RecentSessionPaths) -> String? {
    try? rows(paths.database, sql: "SELECT value FROM meta WHERE key = 'last_sync'").first?.first
  }

  static func isSourceID(_ id: String) -> Bool {
    let parts = id.split(separator: ":")
    return parts.count == 3 && parts[0] == "session"
      && ["claude", "codex"].contains(String(parts[1]))
      && UUID(uuidString: String(parts[2])) != nil
  }

  /// Opens the redacted ax note, never the original provider log.
  static func sourceURL(id: String, paths: RecentSessionPaths = .local()) -> URL? {
    guard isSourceID(id) else { return nil }
    let parts = id.split(separator: ":").map(String.init)
    guard
      let relative = try? rows(
        paths.database,
        sql:
          "SELECT note_path FROM sessions WHERE provider = ? AND session_id = ? AND excluded = 0 AND kind = 'main' LIMIT 1",
        parameters: [parts[1], parts[2]]
      ).first?.first, !relative.isEmpty
    else { return nil }
    let root = paths.vault.resolvingSymlinksInPath().standardizedFileURL
    let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(root.appendingPathComponent("Sessions").path + "/"),
      url.pathExtension == "md", FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }

  static func retrieve(
    _ turns: [RecentSessionTurn], query: String, now: Date = Date(), limit: Int = 8
  )
    -> [RetrievedPassage]
  {
    let tokens = DocumentIndex.terms(query)
    guard !tokens.isEmpty, limit > 0 else { return [] }
    struct Chunk {
      var turn: RecentSessionTurn
      var text: String
      var number: Int
      var terms: Set<String>
    }
    var chunks: [Chunk] = []
    for turn in turns where turn.date >= now.addingTimeInterval(-window) && turn.date <= now {
      var remaining = turn.text[...]
      var number = 0
      while !remaining.isEmpty {
        var end =
          remaining.index(remaining.startIndex, offsetBy: 1800, limitedBy: remaining.endIndex)
          ?? remaining.endIndex
        if end < remaining.endIndex,
          let space = remaining[..<end].suffix(250).lastIndex(where: \.isWhitespace)
        {
          end = remaining.index(after: space)
        }
        let text = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        remaining = remaining[end...]
        number += 1
        let terms = DocumentIndex.terms(text)
        if !terms.isDisjoint(with: tokens) {
          chunks.append(Chunk(turn: turn, text: text, number: number, terms: terms))
        }
      }
    }
    var frequency: [String: Int] = [:]
    for chunk in chunks {
      for term in chunk.terms.intersection(tokens) { frequency[term, default: 0] += 1 }
    }
    let ranked = chunks.enumerated().map { index, chunk in
      let hits = chunk.terms.intersection(tokens)
      let score =
        hits.reduce(0.0) {
          $0 + log(1 + Double(chunks.count + 1) / Double(frequency[$1, default: 0] + 1))
        }
        * (1 + Double(hits.count) / Double(tokens.count))
      return (index, score)
    }.sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      let left = chunks[lhs.0]
      let right = chunks[rhs.0]
      if left.turn.date != right.turn.date { return left.turn.date > right.turn.date }
      return lhs.0 < rhs.0
    }
    var result: [RetrievedPassage] = []
    var perSession: [String: Int] = [:]
    var seen = Set<String>()
    for item in ranked {
      let chunk = chunks[item.0]
      let turn = chunk.turn
      guard perSession[turn.sessionID, default: 0] < 3, seen.insert(chunk.text).inserted else {
        continue
      }
      perSession[turn.sessionID, default: 0] += 1
      let provider = turn.provider == "claude" ? "Claude" : "Codex"
      let day = ISO8601DateFormatter().string(from: turn.date)
      result.append(
        RetrievedPassage(
          ref: "A" + String(result.count + 1),
          documentID: "session:\(turn.provider):\(turn.sessionID)",
          title: "\(provider) · \(turn.title)",
          location:
            "\(day) · \(turn.project) · \(turn.role) turn \(turn.sequence) · excerpt \(chunk.number) · ax:\(turn.sessionID.suffix(8))",
          text: chunk.text))
      if result.count == limit { break }
    }
    return result
  }
}

actor RecentSessionIndex: RecentSessionProviding {
  private let paths: RecentSessionPaths
  private let syncEnabled: Bool
  private let archiveRefresh: @Sendable () async -> Void
  private var refreshTask: Task<Void, Never>?
  private var refreshedAt = Date.distantPast
  private var loadedFor: Date?
  private var lastSyncAttempt = Date.distantPast
  private var turns: [RecentSessionTurn] = []
  private var available = false
  private var syncedAt: String?

  init(
    paths: RecentSessionPaths = .local(), syncEnabled: Bool = true,
    archiveRefresh: (@Sendable () async -> Void)? = nil
  ) {
    self.paths = paths
    self.syncEnabled = syncEnabled
    self.archiveRefresh = archiveRefresh ?? { await RecentSessionIndex.refreshArchive() }
  }

  func retrieve(query: String, now: Date = Date()) async -> RecentSessionContext {
    if Date().timeIntervalSince(refreshedAt) >= 60
      || loadedFor.map({ abs($0.timeIntervalSince(now)) > 60 }) != false
    {
      do {
        // Cache by wall clock; enforce the caller's rolling cutoff again at retrieval.
        turns = try RecentSessionReader.load(paths: paths, now: now)
        loadedFor = now
        available = true
      } catch {
        available = false
        turns = []
      }
      syncedAt = RecentSessionReader.lastSync(paths: paths)
      refreshedAt = Date()
    }
    // Writing and forecasting use the indexed evidence immediately. Refreshing
    // provider archives can take seconds and must never delay the live writer.
    if syncEnabled, refreshTask == nil, Date().timeIntervalSince(lastSyncAttempt) >= 300 {
      lastSyncAttempt = Date()
      let stamp = syncedAt.flatMap(RecentSessionReader.date)
      if stamp.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
        refreshTask = Task {
          await archiveRefresh()
          refreshedAt = .distantPast
          refreshTask = nil
        }
      }
    }
    return RecentSessionContext(
      passages: RecentSessionReader.retrieve(turns, query: query, now: now),
      syncedAt: syncedAt, available: available)
  }

  static func archiveCommand(ax: URL) -> (executable: URL, arguments: [String])? {
    guard let file = try? FileHandle(forReadingFrom: ax) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 512),
      let first = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).first,
      first.hasPrefix("#!")
    else { return nil }
    let interpreter = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
    guard interpreter.hasPrefix("/"), !interpreter.contains(" "),
      URL(fileURLWithPath: interpreter).lastPathComponent.hasPrefix("python"),
      FileManager.default.isExecutableFile(atPath: interpreter)
    else { return nil }
    return (
      URL(fileURLWithPath: interpreter),
      [
        "-c",
        "from ax.config import load; from ax.sync import sync; sync(load())",
      ]
    )
  }

  private static func refreshArchive() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let paths = [
      home.appendingPathComponent(".local/bin/ax").path, "/opt/homebrew/bin/ax",
      "/usr/local/bin/ax",
    ]
    guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      return
    }
    let process = Process()
    // The installed CLI can also enter optional learning, embedding and workshop
    // hooks. Call only its archive function, never those CLI orchestration hooks.
    guard let command = Self.archiveCommand(ax: URL(fileURLWithPath: path)) else { return }
    process.executableURL = command.executable
    process.arguments = command.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      let start = Date()
      defer { if process.isRunning { process.terminate() } }
      while process.isRunning && Date().timeIntervalSince(start) < 20 {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    } catch { return }
  }
}
