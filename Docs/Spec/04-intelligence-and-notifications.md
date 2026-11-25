# Transcripts, ad skipping and new-episode notifications

Three features, iPhone/iPad only (the watch is unaffected). Everything runs on the device: audio and transcripts
never leave it.

## 1. On-device transcription

**Engine** – `SpeechAnalyzer` + `SpeechTranscriber` (Speech framework, iOS 26) with
`attributeOptions: [.audioTimeRange]`, so every result carries word-level time ranges (`AttributedString` runs).
Language models are installed on demand via `AssetInventory.assetInstallationRequest(supporting:)` (one-time
download per language, progress shown). No microphone or speech-recognition permission is needed for file analysis.

**Audio source** – the downloaded files (`DownloadManager.localPlayback(for:)`). Items that aren't downloaded are
downloaded first through the regular download manager (auth, pinning, cellular rule, background session); the
download stays afterwards. Multi-file items are transcribed file by file; times are offset by `AudioTrack.offset`.

**Model** (`HearthModel/Transcript.swift`) – `Transcript { itemID, localeIdentifier, createdAt, duration,
segments: [TranscriptSegment] }`, `TranscriptSegment { start, end, text, words: [TranscriptWord] }`,
`TranscriptWord { text, start, end }`. Pure helpers: segment/word lookup by time (binary search), search, plain-text
export. Compact JSON coding keys (a 2 h episode ≈ 1 MB).

**Storage** (`HearthData/Transcripts/TranscriptStore.swift`, `HearthData.shared.transcripts`) – JSON files in
`Application Support/Transcripts/` plus a small index (item → has transcript, ad segments, created at). Ad segments
are kept in memory (tiny) so the player can read them on every tick. Removed with the connection; kept when a
download is deleted. "Delete all transcripts" in settings.

**Pipeline** (`HearthIntelligence` package module, `TranscriptionService.shared`, `@MainActor @Observable`) – one job
at a time, others queued. Phases: queued → downloading (progress) → preparing language model (progress) →
transcribing (progress) → detecting ads (progress) → finished / failed / cancelled. Each job publishes progress and a
remaining-time estimate.

**Time estimate** (`TimeEstimator`, pure + tested) – before start: duration ÷ measured transcription speed (audio
seconds per second; default 20×, then an exponential moving average of real runs persisted per device) + ad windows
× measured seconds per window (default 4 s) + "plus download (size)" when not downloaded + "plus one-time language
download" when the model isn't installed. While running: remaining audio ÷ the speed measured in this run (after
10 s), smoothed.

**Background** – each job is backed by a `BGContinuedProcessingTask`
(`<bundle>.transcription.<id>`, iOS 26): it keeps running when the user leaves the app and the system shows its
progress; expiry cancels the job cleanly.

**UI**
- *Transcription sheet* (episode page, player panel): explains the three steps (download, on-device speech
  recognition, ad detection) with privacy note, language picker (default: podcast language → app language), "detect
  ads" toggle, estimate card with breakdown, start. Turns into a live progress view (step list with checkmarks,
  progress, remaining time, cancel) and ends with "Show transcript".
- *Transcript view*: paragraphs with timestamps; the word being spoken is highlighted and followed while the item
  plays ("follow" pauses when the user scrolls, button to jump back); tap a paragraph to play from there; search with
  match count and next/previous; ad blocks marked; copy/share as text; re-run ad detection; delete.
- *Player panel*: new "Transcript" page (live highlighting) when a transcript exists, otherwise a "Create
  transcript" prompt.
- *Episode page*: "Transcript" row (create / progress / open, number of detected ads).

## 2. Ad detection and skipping

**Detection** (`AdDetector`) on the transcript:
- *Apple Intelligence* (`FoundationModels`, `SystemLanguageModel.default` available): the transcript is split into
  numbered lines (one per segment) and windows that fit the context (~1 800 tokens, 2 lines overlap). Each window is
  a fresh `LanguageModelSession` with guided generation (`@Generable AdWindowResult { ads: [AdBlock{firstLine,
  lastLine, advertiser?}] }`). Lines map back to times; blocks are merged across windows and validated (8 s – 6 min).
- *Fallback / no Apple Intelligence*: `HeuristicAdDetector` (pure, tested) – scores segments with German and English
  sponsor cues (promo codes, "sponsored by", "Werbung", "Rabattcode", URLs, "präsentiert von", …), clusters nearby
  hits and extends them to sentence bounds. Windows where the model fails (guardrails, context) also use it.
- The result records the method; UI shows which one ran.

**Skipping** (`HearthPlayback`, `AdSkipLogic` pure + tested): with "Skip ads automatically" on, entering an ad
segment while playing seeks to its end – once per segment per item (seeking back into it plays it). A toast
"Ad skipped · Undo" appears in the player. With the setting off, a "Skip ad" button appears while inside an ad. Ad
segments are marked on the scrubber.

## 3. New-episode notifications

audiobookshelf can't send push notifications to third-party apps, so Hearth checks itself:
- **When**: background app refresh (existing sync task; earliest 30 min while notifications are on – iOS decides the
  actual time, so notifications can be delayed) and live `itemAdded` socket events while the app runs.
- **What**: `recentEpisodes(library:)` of every podcast library; `NewEpisodeTracker` (HearthData, pure + tested)
  remembers seen episode ids per library. The first check after enabling only records a baseline (no flood of old
  episodes). Muted podcasts are skipped. Up to 4 notifications per check, otherwise one summary.
- **Notification**: podcast name as title, episode title as body, cover as attachment, grouped per podcast
  (`threadIdentifier`), actions "Play" and "Download". Tapping opens the episode.
- **Settings**: global toggle (asks for permission; explains when denied with a link to Settings), per-podcast toggle
  list; bell toggle in the podcast page's toolbar.

## Settings

New screen "Transcripts & Ads": skip ads automatically, detect ads after transcribing, Apple Intelligence status,
storage used, delete all transcripts. New screen "Notifications": new episodes on/off, per-podcast toggles.

## Code layout

| Where | What |
| --- | --- |
| `HearthModel/Transcript.swift` | Transcript, AdSegment, lookup helpers |
| `HearthData/Transcripts/` | TranscriptStore, NewEpisodeTracker, settings keys |
| `HearthIntelligence` (new module) | TranscriptionService, SpeechTranscriptionEngine, AdDetector (LLM + heuristic), TimeEstimator |
| `HearthPlayback/AudioPlayer+AdSkipping.swift`, `Logic/AdSkipLogic.swift` | auto skip, undo, manual skip |
| `App/iOS/Intelligence/` | sheet, transcript view, player page, settings, background task bridge |
| `App/iOS/System/EpisodeNotifier.swift` | checks, notifications, actions, delegate |
| `App/Resources/iOS/Intelligence.xcstrings`, `Notifications.xcstrings` | strings (en + de) |
