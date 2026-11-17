import assert from "node:assert/strict"
import { mkdir } from "node:fs/promises"
import { chromium } from "playwright"
import { preview } from "vite"

// Exercise real browser state and interactions with synthetic text/word fixtures.
// No real audio, user files, model calls, credentials or external services are used.
const server = await preview({ preview: { port: 4320, strictPort: false }, logLevel: "warn" })
const url = server.resolvedUrls?.local[0]
if (!url) throw new Error("No preview URL")
const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1440, height: 980 } })
const problems = []
page.on("pageerror", (error) => problems.push(error.message))
await mkdir("checks", { recursive: true })
try {
  await page.goto(url, { waitUntil: "networkidle" })
  await page.getByRole("button", { name: "New meeting" }).first().click()
  assert.equal(await page.getByRole("dialog").count(), 0)
  await page.getByRole("heading", { name: "Untitled meeting", exact: true }).waitFor()
  await page.locator(".meeting-item").first().dblclick()
  await page.getByLabel("Meeting name", { exact: true }).fill("Accent evaluation")
  await page.getByLabel("Meeting name", { exact: true }).press("Enter")
  await page.getByRole("heading", { name: "Accent evaluation" }).waitFor()
  assert.equal(
    await page
      .locator(".meeting-item")
      .first()
      .evaluate((element) => getComputedStyle(element).userSelect),
    "none"
  )
  await page.getByLabel("Meeting actions", { exact: true }).click()
  await page.getByRole("button", { name: "Add a passage", exact: true }).first().click()
  await page.getByLabel("Passage or note").fill("Let's compare para kit on English and Spanish.")
  await page.getByRole("button", { name: "Add passage", exact: true }).click()
  await page
    .locator(".passage-text")
    .filter({ hasText: "Let's compare para kit on English and Spanish." })
    .waitFor()
  await page.getByRole("button", { name: "Edit document", exact: true }).click()
  await page
    .getByLabel("Edit transcript document", { exact: true })
    .fill("Let's compare Parakeet on English and Spanish.")
  await page.getByRole("button", { name: "Save document", exact: true }).click()
  await page
    .locator(".passage-text")
    .filter({ hasText: "Let's compare Parakeet on English and Spanish." })
    .waitFor()
  await page.getByRole("button", { name: "Original", exact: true }).click()
  await page
    .locator(".passage-text")
    .filter({ hasText: "Let's compare para kit on English and Spanish." })
    .waitFor()
  await page.getByRole("button", { name: "Repaired", exact: true }).click()
  await page.getByLabel("Search transcript").fill("no-such-word")
  await page.getByRole("heading", { name: /No passages match/ }).waitFor()
  await page.getByLabel("Search transcript").fill("")
  const inputChooser = page.waitForEvent("filechooser")
  await page.getByRole("button", { name: "Edit meeting context", exact: true }).click()
  await page.getByRole("button", { name: "Add documents to this meeting" }).click()
  await (await inputChooser).setFiles({
    name: "evaluation-brief.md",
    mimeType: "text/markdown",
    buffer: Buffer.from(
      "# Evaluation\nCompare the user's English and Spanish recordings on identical microphone audio."
    ),
  })
  await page.getByText("evaluation-brief.md", { exact: true }).waitFor()
  await page.getByRole("button", { name: "Save meeting context", exact: true }).click()
  await page.getByRole("button", { name: "Edit meeting context", exact: true }).waitFor()
  await page.getByRole("button", { name: /Your vocabulary/ }).click()
  await page.getByRole("button", { name: "Add a term", exact: true }).click()
  await page.getByLabel("Term or name").fill("Parakeet")
  await page.getByLabel("Possible mishearings").fill("para kit, parakeets")
  await page.getByLabel("Meaning in your work").fill("The local speech recognition model.")
  await page.getByRole("button", { name: "Add to glossary", exact: true }).click()
  await page.getByRole("heading", { name: "Parakeet", exact: true }).waitFor()
  await page.getByRole("button", { name: "Remove Parakeet", exact: true }).click()
  await page.getByRole("button", { name: "Undo", exact: true }).click()
  await page.getByRole("heading", { name: "Parakeet", exact: true }).waitFor()
  await page.reload({ waitUntil: "networkidle" })
  await page.getByRole("heading", { name: "Accent evaluation", exact: true }).waitFor()
  await page
    .locator(".passage-text")
    .filter({ hasText: "Let's compare Parakeet on English and Spanish." })
    .waitFor()
  await page.getByLabel("Meeting actions", { exact: true }).click()
  await page.getByRole("button", { name: "Export meeting", exact: true }).click()
  await page.getByRole("heading", { name: "Narrated transcript", exact: true }).waitFor()
  assert.equal(await page.getByLabel("Narration voice", { exact: true }).inputValue(), "you")
  assert.equal(await page.getByLabel("Narration language", { exact: true }).inputValue(), "English")
  assert.equal(
    await page.getByRole("button", { name: "Prepare local narration", exact: true }).isDisabled(),
    true
  )
  assert.equal(
    await page.getByRole("button", { name: "Narrated transcript · WAV", exact: true }).isDisabled(),
    true
  )
  await page
    .getByRole("heading", { name: "Narrated transcript", exact: true })
    .scrollIntoViewIfNeeded()
  await page.screenshot({
    path: "checks/narrated-export-desktop-light.png",
    animations: "disabled",
  })
  await page.emulateMedia({ colorScheme: "dark" })
  await page.screenshot({ path: "checks/narrated-export-desktop-dark.png", animations: "disabled" })
  await page.emulateMedia({ colorScheme: "light" })
  await page.setViewportSize({ width: 390, height: 844 })
  await page
    .getByRole("heading", { name: "Narrated transcript", exact: true })
    .scrollIntoViewIfNeeded()
  assert.equal(
    await page.locator("dialog").evaluate((dialog) => dialog.scrollWidth > dialog.clientWidth),
    false
  )
  await page.screenshot({ path: "checks/narrated-export-phone.png", animations: "disabled" })
  await page.setViewportSize({ width: 1440, height: 980 })
  const download = page.waitForEvent("download")
  await page.getByRole("button", { name: "Complete JSON record", exact: true }).click()
  assert.match((await download).suggestedFilename(), /Accent evaluation\.json/)
  await page.getByRole("button", { name: "Close dialog", exact: true }).click()
  await page.getByLabel("Meeting actions", { exact: true }).click()
  await page.getByRole("button", { name: "Speaker names", exact: true }).click()
  // A manually entered note supplies no acoustic identity to enroll.
  assert.equal(
    await page.getByRole("button", { name: /Remember voice|Add voice sample/ }).count(),
    0
  )
  await page.getByRole("button", { name: "Close dialog", exact: true }).click()
  await page.getByRole("button", { name: "Settings", exact: true }).click()
  await page.getByRole("heading", { name: "Saved people", exact: true }).waitFor()
  await page.getByLabel("Person’s name", { exact: true }).fill("UI control check")
  // Browser preview cannot enroll or pretend to play a local voice sample.
  assert.equal(
    await page.getByRole("button", { name: "Import voice sample", exact: true }).isDisabled(),
    true
  )
  assert.equal(
    await page
      .getByRole("button", { name: "Learn my voice from a recording", exact: true })
      .isDisabled(),
    true
  )
  assert.equal(
    await page.getByRole("button", { name: "Download speaker model", exact: true }).isDisabled(),
    true
  )
  await page.getByLabel("Person’s name", { exact: true }).fill("")
  await page.getByRole("heading", { name: "Saved people", exact: true }).scrollIntoViewIfNeeded()
  await page.screenshot({ path: "checks/voice-settings-desktop-light.png", animations: "disabled" })
  await page.emulateMedia({ colorScheme: "dark" })
  await page.screenshot({ path: "checks/voice-settings-desktop-dark.png", animations: "disabled" })
  await page.emulateMedia({ colorScheme: "light" })
  await page.setViewportSize({ width: 390, height: 844 })
  await page.getByRole("heading", { name: "Saved people", exact: true }).scrollIntoViewIfNeeded()
  assert.equal(
    await page.locator("dialog").evaluate((dialog) => dialog.scrollWidth > dialog.clientWidth),
    false
  )
  await page.screenshot({ path: "checks/voice-settings-phone.png", animations: "disabled" })
  await page.setViewportSize({ width: 1440, height: 980 })
  await page.getByText("Shared work context", { exact: true }).click()
  await page
    .getByLabel("Shared work context", { exact: true })
    .fill("We build classification and evaluation workflows.")
  await page.getByRole("button", { name: "Save work context", exact: true }).click()
  await page.getByLabel("Enable meeting assistant").click()
  await page.getByRole("button", { name: "Close dialog", exact: true }).click()
  const saved = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("aside-browser-workspace-v1"))
  )
  assert.equal(saved.state.settings.assistantEnabled, false)
  assert.equal(
    saved.state.settings.workContext,
    "We build classification and evaluation workflows."
  )
  assert.equal(saved.meetings[0].document.author, "user")
  assert.equal(saved.meetings[0].segments[0].status, "manual")
  assert.equal(
    saved.meetings[0].segments[0].rawText,
    "Let's compare para kit on English and Spanish."
  )
  assert.equal(saved.meetings[0].document.revision, 1)
  assert.equal(await page.locator(".passage-time").count(), 0)
  assert.equal(await page.locator(".transcript-document button").count(), 0)
  assert.equal(saved.meetings[0].documentIDs.length, 1)
  assert.equal(saved.state.glossary.length, 1)
  await page.screenshot({ path: "checks/workspace-desktop.png", fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  await page.screenshot({ path: "checks/workspace-phone.png", fullPage: true })
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth
    ),
    false
  )
  const floatingPage = await browser.newPage({ viewport: { width: 390, height: 600 } })
  floatingPage.on("pageerror", (error) => problems.push(error.message))
  await floatingPage.goto(`${url}#context`, { waitUntil: "networkidle" })
  await floatingPage.getByRole("main", { name: "Floating contextual help" }).waitFor()
  assert.equal(await floatingPage.locator(".meeting-sidebar, .aside-appbar").count(), 0)
  assert.equal(await floatingPage.getByRole("tab", { name: "Ask anything" }).count(), 1)
  assert.equal(
    await floatingPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    true
  )
  await floatingPage.screenshot({
    path: "checks/floating-context-light.png",
    animations: "disabled",
  })
  await floatingPage.emulateMedia({ colorScheme: "dark" })
  await floatingPage.screenshot({
    path: "checks/floating-context-dark.png",
    animations: "disabled",
  })
  // A single canonical caption can contain several measured voices. This fixture
  // is synthetic and isolated from the browser workspace tested above.
  const mixedWorkspace = structuredClone(saved)
  const mixed = mixedWorkspace.meetings[0]
  mixed.title = "Synthetic mixed voices"
  mixed.document = {
    speakerNames: { "Speaker 2": "Taylor" },
    blocks: [
      {
        id: "written-you",
        speaker: "You",
        sourceIDs: ["fixture-track:-1"],
        text: "I will ask Taylor for an update.",
        needsReview: false,
      },
      {
        id: "written-other",
        speaker: "Speaker 2",
        sourceIDs: ["fixture-track:-1"],
        text: "I can provide it.",
        needsReview: false,
      },
    ],
    text: "I will ask Taylor for an update.\n\nI can provide it.",
    sourceFingerprint: "fixture-track:-1:0",
    revision: 1,
    createdAt: mixed.createdAt,
    author: "assistant",
  }
  mixed.documentHistory = []
  mixed.status = "ready"
  mixed.duration = 4
  mixed.speakerNames = { "Speaker 2": "Taylor" }
  mixed.audioTracks = [
    { id: "fixture-track", label: "Imported audio", filename: "fixture.wav", duration: 4 },
  ]
  mixed.segments = [
    {
      id: "fixture-track:-1",
      start: 0,
      end: 4,
      speaker: "Mixed speakers",
      rawText: "Mine. Yours. Both. Again.",
      text: "Mine. Yours. Both. Again.",
      status: "raw",
      revision: 0,
      corrections: [],
      captionWords: [
        { text: "Mine.", start: 0, end: 1, speaker: "You" },
        { text: "Yours.", start: 1, end: 2, speaker: "Speaker 2" },
        { text: "Both.", start: 2, end: 3, speaker: "Speaker 2 + You" },
        { text: "Again.", start: 3, end: 4, speaker: "You" },
      ],
    },
  ]
  mixedWorkspace.state.meeting = mixed
  mixedWorkspace.state.meetings = [
    {
      id: mixed.id,
      title: mixed.title,
      createdAt: mixed.createdAt,
      duration: 4,
      segmentCount: 1,
      status: "ready",
    },
  ]
  const mixedPage = await browser.newPage({ viewport: { width: 1440, height: 980 } })
  mixedPage.on("pageerror", (error) => problems.push(error.message))
  mixedPage.on("console", (message) => {
    if (message.type() === "error" && /same key|unique.*key/i.test(message.text()))
      problems.push(message.text())
  })
  await mixedPage.addInitScript((workspace) => {
    if (!sessionStorage.getItem("aside-mixed-fixture-initialized")) {
      localStorage.setItem("aside-browser-workspace-v1", JSON.stringify(workspace))
      sessionStorage.setItem("aside-mixed-fixture-initialized", "true")
    }
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text) => {
          window.__asideCopiedFixture = text
        },
      },
    })
  }, mixedWorkspace)
  await mixedPage.goto(url, { waitUntil: "networkidle" })
  await mixedPage.getByRole("button", { name: "Original", exact: true }).click()
  const rawRuns = mixedPage.locator('[data-source-segment="fixture-track:-1"]')
  assert.equal(await rawRuns.count(), 4)
  assert.equal(await mixedPage.locator('[id="segment-fixture-track:-1"]').count(), 1)
  assert.equal(await mixedPage.locator(".passage-text").count(), 4)
  await rawRuns.first().evaluate((element) => {
    element.dataset.smokeIdentity = "retained"
  })
  await mixedPage.getByLabel("Only me", { exact: true }).check()
  assert.deepEqual(
    (await rawRuns.allTextContents()).map((text) => text.trim()),
    ["Mine.", "Again."]
  )
  await mixedPage.getByRole("button", { name: /^(Copy transcript|Copied)$/ }).click()
  assert.equal(await mixedPage.evaluate(() => window.__asideCopiedFixture), "Mine.\n\nAgain.")
  await mixedPage.getByLabel("Only me", { exact: true }).uncheck()
  assert.equal(await rawRuns.first().getAttribute("data-smoke-identity"), "retained")
  await mixedPage
    .getByRole("button", { name: "Rename speaker Taylor", exact: true })
    .click({ button: "right" })
  await mixedPage.getByRole("menuitem", { name: "Rename participant…", exact: true }).click()
  const inlineName = mixedPage.getByRole("textbox", { name: "Name for Taylor", exact: true })
  await inlineName.fill("Jordan")
  await inlineName.press("Enter")
  await mixedPage.getByRole("button", { name: "Rename speaker Jordan", exact: true }).waitFor()
  const renamed = await mixedPage.evaluate(
    () => JSON.parse(localStorage.getItem("aside-browser-workspace-v1")).meetings[0]
  )
  assert.equal(renamed.speakerNames["Speaker 2"], "Jordan")
  assert.deepEqual(renamed.segments, mixed.segments)
  assert.equal(renamed.document.text, "I will ask Jordan for an update.\n\nI can provide it.")
  assert.equal(renamed.documentHistory.at(-1).text, mixed.document.text)
  await mixedPage.getByRole("button", { name: "Rename speaker Jordan", exact: true }).click()
  await mixedPage.getByRole("textbox", { name: "Name for Jordan", exact: true }).fill("Discarded")
  await mixedPage.getByRole("textbox", { name: "Name for Jordan", exact: true }).press("Escape")
  await mixedPage.getByRole("button", { name: "Rename speaker Jordan", exact: true }).waitFor()
  await mixedPage.getByLabel("Meeting actions", { exact: true }).click()
  await mixedPage.getByRole("button", { name: "Speaker names", exact: true }).click()
  await mixedPage.getByLabel("Speaker 2", { exact: true }).fill("Robin")
  assert.equal(await mixedPage.getByLabel("Mixed speakers", { exact: true }).count(), 0)
  assert.equal(
    await mixedPage.getByRole("button", { name: /Remember voice|Add voice sample/ }).count(),
    0
  )
  await mixedPage.getByRole("button", { name: "Save speaker names", exact: true }).click()
  await mixedPage.getByRole("button", { name: /^(Copy transcript|Copied)$/ }).click()
  assert.match(await mixedPage.evaluate(() => window.__asideCopiedFixture), /Robin:\nYours\./)
  const retained = await mixedPage.evaluate(
    () => JSON.parse(localStorage.getItem("aside-browser-workspace-v1")).meetings[0].segments[0]
  )
  assert.deepEqual(retained, mixed.segments[0])
  await mixedPage.getByRole("button", { name: "Repaired", exact: true }).click()
  const writtenDocument = mixedPage.getByRole("article", {
    name: "Repaired transcript document",
    exact: true,
  })
  assert.match(await writtenDocument.textContent(), /I will ask Robin for an update\./)
  const writtenPassage = writtenDocument.locator(".passage-text").first()
  await writtenPassage.evaluate((element) => {
    const range = document.createRange()
    range.selectNodeContents(element.lastChild)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  })
  await writtenPassage.click({ button: "right", position: { x: 80, y: 30 } })
  await mixedPage.getByRole("menuitem", { name: "Copy selected text", exact: true }).click()
  assert.equal(
    await mixedPage.evaluate(() => window.__asideCopiedFixture),
    "I will ask Robin for an update."
  )
  await writtenDocument.click({ button: "right", position: { x: 90, y: 75 } })
  await mixedPage.getByRole("menuitem", { name: "Copy transcript", exact: true }).click()
  assert.match(
    await mixedPage.evaluate(() => window.__asideCopiedFixture),
    /I will ask Robin for an update\./
  )
  const fixtureMeeting = mixedPage.getByRole("button", { name: /Synthetic mixed voices.*passages/ })
  await fixtureMeeting.click({ button: "right" })
  await mixedPage.getByRole("menuitem", { name: "Rename meeting…", exact: true }).waitFor()
  assert.equal(
    await mixedPage.getByRole("menuitem", { name: "Delete meeting…", exact: true }).isDisabled(),
    true
  )
  await mixedPage.screenshot({ path: "checks/context-menu-light.png", animations: "disabled" })
  await mixedPage.emulateMedia({ colorScheme: "dark" })
  await mixedPage.screenshot({ path: "checks/context-menu-dark.png", animations: "disabled" })
  await mixedPage.getByRole("menuitem", { name: "Rename meeting…", exact: true }).click()
  await mixedPage.getByLabel("Meeting name", { exact: true }).waitFor()
  await mixedPage.getByLabel("Meeting name", { exact: true }).press("Escape")
  await mixedPage.emulateMedia({ colorScheme: "light" })
  await mixedPage.reload({ waitUntil: "networkidle" })
  await mixedPage.getByRole("button", { name: "Repaired", exact: true }).click()
  assert.match(
    await mixedPage.getByRole("article", { name: "Repaired transcript document" }).textContent(),
    /I will ask Robin for an update\./
  )
  await mixedPage.getByRole("button", { name: "Original", exact: true }).click()
  await mixedPage.screenshot({
    path: "checks/mixed-speakers-desktop-light.png",
    animations: "disabled",
  })
  await mixedPage.emulateMedia({ colorScheme: "dark" })
  await mixedPage.setViewportSize({ width: 390, height: 844 })
  assert.equal(
    await mixedPage.evaluate(() => document.documentElement.scrollWidth > innerWidth),
    false
  )
  await mixedPage.screenshot({
    path: "checks/mixed-speakers-phone-dark.png",
    animations: "disabled",
  })
  await mixedPage.close()
  const processingWorkspace = structuredClone(mixedWorkspace)
  const processingMeeting = processingWorkspace.meetings[0]
  processingMeeting.title = "Finishing a test recording"
  processingMeeting.status = "processing"
  processingMeeting.pendingStage = "recognition"
  processingMeeting.document = undefined
  processingWorkspace.state.meeting = processingMeeting
  processingWorkspace.state.meetings = processingWorkspace.state.meetings.map((value) => ({
    ...value,
    title: processingMeeting.title,
    status: "processing",
  }))
  const progressPage = await browser.newPage({ viewport: { width: 1440, height: 980 } })
  progressPage.on("pageerror", (error) => problems.push(error.message))
  await progressPage.addInitScript((workspace) => {
    localStorage.setItem("aside-browser-workspace-v1", JSON.stringify(workspace))
  }, processingWorkspace)
  await progressPage.goto(url, { waitUntil: "networkidle" })
  const processingStatus = progressPage.getByRole("status", {
    name: "Transcript progress",
    exact: true,
  })
  await processingStatus.getByText("Preparing final transcript…", { exact: true }).waitFor()
  assert.equal(await progressPage.locator(".transcript-document").getAttribute("aria-busy"), "true")
  assert.match(await progressPage.locator(".meeting-list").textContent(), /Finalizing transcript…/)
  await progressPage.screenshot({
    path: "checks/transcript-processing-light.png",
    animations: "disabled",
  })
  processingWorkspace.state.meeting.pendingStage = "polish"
  processingWorkspace.state.runtime.assistantStatus = "Polishing transcript"
  await progressPage.evaluate(
    (state) => window.__asideReceive({ event: "state", state }),
    processingWorkspace.state
  )
  await processingStatus.getByText("Writing final transcript…", { exact: true }).waitFor()
  await progressPage.emulateMedia({ colorScheme: "dark" })
  await progressPage.screenshot({
    path: "checks/transcript-processing-dark.png",
    animations: "disabled",
  })
  processingWorkspace.state.meeting.status = "complete"
  delete processingWorkspace.state.meeting.pendingStage
  processingWorkspace.state.meeting.document = mixed.document
  processingWorkspace.state.meetings[0].status = "complete"
  processingWorkspace.state.runtime.assistantStatus = "Ready"
  await progressPage.evaluate(
    (state) => window.__asideReceive({ event: "state", state }),
    processingWorkspace.state
  )
  await processingStatus.waitFor({ state: "detached" })
  assert.equal(
    await progressPage.locator(".transcript-document").getAttribute("aria-busy"),
    "false"
  )
  assert.equal(
    (await progressPage.locator(".meeting-list").textContent()).includes("Finalizing transcript…"),
    false
  )
  await progressPage.close()
  assert.deepEqual(problems, [])
  console.log(
    "UI smoke passed: creation, passage editing, raw preservation, search, documents, vocabulary undo, persistence, export, preferences, native voice controls, floating context and phone layout."
  )
} finally {
  await browser.close()
  await server.close()
}
