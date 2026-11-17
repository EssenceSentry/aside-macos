import Foundation

@testable import Aside

/// Unit fixtures never consult or synchronize the user's private session archive.
struct EmptyRecentSessions: RecentSessionProviding {
  func retrieve(query: String, now: Date) async -> RecentSessionContext {
    RecentSessionContext(passages: [], syncedAt: nil, available: false)
  }
}

func fixtureIntelligence(transport: any AssistantTransport) -> MeetingIntelligence {
  MeetingIntelligence(transport: transport, recentSessions: EmptyRecentSessions())
}
