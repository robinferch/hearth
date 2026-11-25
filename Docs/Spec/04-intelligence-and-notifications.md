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
seconds per second; default 40×, then an exponential moving average of real runs persisted per device) + ad windows
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

**Detection** (`AdDetector`) on the transcript. The transcript is rendered as numbered lines (one sentence each) and
split into windows that fit the model; each window goes to an `AdModelRunner`, which answers with line ranges
(`AdBlockCandidate{firstLine, lastLine, advertiser?}`). Lines map back to times; blocks are merged across windows and
validated (8 s – 6 min). Windows the model can't handle (guardrails, errors) use the keyword heuristics; a wrong API
key or missing credit stops the run with a clear error. The analysis records method and model name ("Found with …").

Providers (setting "Find ads with", resolved by `AdDetectionPlan`; unavailable providers fall back to keywords with
the reason shown):
- *Automatic* (default): Apple Intelligence where available, otherwise keywords.
- *Apple Intelligence* (`SystemLanguageModel`, 4 500-character windows, guided generation with `@Generable`).
- *Model on this iPhone* (hidden for now, `AdDetectionProvider.offersLocalModels = false`: without the
  increased-memory-limit entitlement it would always fall back to keywords; a stored choice counts as *Automatic*): an
  open model run with MLX through FoundationModels (`MLXLanguageModel` from
  mlx-swift-lm's `MLXFoundationModels`, iOS 27), no content restrictions. Models (`LocalAdModel.all`): Gemma 4 E2B
  (recommended, 3.6 GB) and Gemma 4 E4B (5.2 GB, 12 GB devices) – instruction-tuned 4-bit MLX builds.
  An episode's analysis may take at most 60 s (`timeBudget`; the running request is cancelled, the rest uses
  keywords), so the model only reads the candidate passages (`CandidateSelector`, ~10 % of the text, all ten
  labelled ads), one passage of ~1 500 characters per request, and answers in plain text ("120-131 Brand",
  `AdDetector.textInstructions` / `parseTextAnswer`) – guided generation made these models return nothing.
  Benchmark (three hand-labelled German episodes, 10 ad blocks, Mac timings): Gemma 4 E2B 8/10 blocks at 85 %
  precision in 10 s; E4B 9/10 at 94 % in 24 s; LFM3 1.7B 8/10 at 40 %; Llama 3.2 3B 4/10; Qwen 3.5 2B and
  Gemma 3 1B far too slow or unusable. Apple Intelligence (whole transcript): 10/10 at 78 %.
  Memory: iOS terminates an app above its per-process limit (~3.6 GB on a 12 GB iPhone 17 Pro Max without the
  `com.apple.developer.kernel.increased-memory-limit` entitlement); Gemma 4 E2B peaks at ~3.1 GB. A model is only
  offered and run when `os_proc_available_memory()` covers `LocalAdModel.memoryNeeded` (E2B 3.6 GB, E4B 5.6 GB), so
  without that entitlement local models fall back to keywords instead of crashing. MLX's buffer cache is capped
  (64 MB) and cleared after each episode. iOS also terminates apps using the GPU in the background, so requests only
  run while the app is active and are cancelled when it resigns active (the rest uses keywords).
  Small on-device models (and Apple Intelligence) mark only an ad's core; each block is widened to the cue lines of
  its candidate passage (`extendsToCuePassages`, max 6 min), which raised the ad time found from ~45 % to ~58 %.
  Downloaded from Hugging Face into `Application Support/Models` (not purged, no backup) from the settings; the model
  is loaded only while ads are found and evicted afterwards. Models too large for the device's memory are disabled.
  The app target links MLXLLM, MLXLMCommon, MLXFoundationModels, HuggingFace and Tokenizers; the two adapters the
  `MLXHuggingFace` macros would generate are written out (`App/iOS/Intelligence/LocalModels`) so CI needs no macro
  trust. Building needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`, also in CI).
- *Claude (own API key)*: Messages API over HTTPS (no official Swift SDK), the whole transcript in one request
  (no chunking below ~25 hours of speech: 1 500 000-character windows in the 1M context), structured outputs (`output_config.format` JSON schema), server-side refusal
  fallback (`fallbacks: "default"`, Opus 5.5 / Sonnet 5.5). Models: Claude Opus 5.5 (default), Sonnet 5.5, Haiku 5.5,
  with a cost estimate per hour of speech. The key is checked with a free `GET /v1/models` and stored in the Keychain
  on the device. Only the transcript text is sent to Anthropic; the sheet says so.
- *Keywords only*: `HeuristicAdDetector` (pure, tested) – German and English sponsor cues (promo codes, "sponsored
  by", "Werbung", "Rabattcode", URLs, "präsentiert von", …) at sentence precision; it never extends into sentences
  without cues.

Time estimates use the provider's window size and a per-provider measured time per request.

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
