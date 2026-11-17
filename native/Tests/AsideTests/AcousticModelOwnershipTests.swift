import Foundation
import Testing

@testable import Aside

private actor AcousticLifetimeSignal {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func signal() {
    signalled = true
    let ready = waiters
    waiters.removeAll()
    for waiter in ready { waiter.resume() }
  }
}

/// Synthetic resources exercise the same actor suspension/retirement ordering
/// without loading Core ML or consulting the user's application-data directory.
private actor AcousticLifetimeHarness {
  private var ownership = AcousticModelOwnership()
  private var generation = 1
  private var retired: [Int] = []

  func use(started: AcousticLifetimeSignal, until finish: AcousticLifetimeSignal) async throws
    -> Int
  {
    let ticket = ownership.beginUse()
    defer { ownership.endUse(ticket) }
    let resource = generation
    await started.signal()
    await finish.wait()
    try Task.checkCancellation()
    return resource
  }

  func retire(
    started: AcousticLifetimeSignal? = nil, until finish: AcousticLifetimeSignal? = nil
  ) async -> Bool {
    guard let ticket = ownership.beginRetirement() else { return false }
    defer { ownership.endRetirement(ticket) }
    let old = generation
    generation += 1  // Detach before suspension, exactly as the owning speech actor does.
    await started?.signal()
    await finish?.wait()
    retired.append(old)
    return true
  }

  func retiredGenerations() -> [Int] { retired }
}

@Test func acousticRetirementSkipsSuspendedRecognitionWithoutDiscardingItsResource() async throws {
  let models = AcousticLifetimeHarness()
  let started = AcousticLifetimeSignal()
  let finish = AcousticLifetimeSignal()
  let recognition = Task { try await models.use(started: started, until: finish) }
  await started.wait()
  #expect(await models.retire() == false)
  #expect(await models.retiredGenerations().isEmpty)
  await finish.signal()
  #expect(try await recognition.value == 1)
  #expect(await models.retire())
  #expect(await models.retiredGenerations() == [1])
}

@Test func acousticRetirementCannotUnloadNewWorkStartedDuringOldGenerationCleanup() async throws {
  let models = AcousticLifetimeHarness()
  let retiring = AcousticLifetimeSignal()
  let finishRetirement = AcousticLifetimeSignal()
  let retirement = Task { await models.retire(started: retiring, until: finishRetirement) }
  await retiring.wait()
  let recognizing = AcousticLifetimeSignal()
  let finishRecognition = AcousticLifetimeSignal()
  let recognition = Task {
    try await models.use(started: recognizing, until: finishRecognition)
  }
  await recognizing.wait()
  #expect(await models.retire() == false)
  await finishRetirement.signal()
  #expect(await retirement.value)
  #expect(await models.retiredGenerations() == [1])
  // Finishing an old retirement must not clear a newer operation's ownership.
  #expect(await models.retire() == false)
  await finishRecognition.signal()
  #expect(try await recognition.value == 2)
  #expect(await models.retire())
  #expect(await models.retiredGenerations() == [1, 2])
}

@Test func cancelledAcousticWarmupRetainsOwnershipUntilItsAwaitActuallyFinishes() async throws {
  let models = AcousticLifetimeHarness()
  let started = AcousticLifetimeSignal()
  let finish = AcousticLifetimeSignal()
  let warmup = Task { try await models.use(started: started, until: finish) }
  await started.wait()
  warmup.cancel()
  #expect(await models.retire() == false)
  await finish.signal()
  do {
    _ = try await warmup.value
    Issue.record("The cancelled warmup unexpectedly completed normally")
  } catch is CancellationError {
    // Deferred ownership release must also run on cancellation.
  }
  #expect(await models.retire())
}

@Test func duplicateAcousticUseCompletionCannotReleaseAnotherOperation() {
  var ownership = AcousticModelOwnership()
  let first = ownership.beginUse()
  let second = ownership.beginUse()
  ownership.endUse(first)
  ownership.endUse(first)
  #expect(ownership.beginRetirement() == nil)
  ownership.endUse(second)
  #expect(ownership.beginRetirement() != nil)
}
