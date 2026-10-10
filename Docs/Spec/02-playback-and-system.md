# Hearth – Playback & system integration spec

Behavioural spec (clean-room; no code copied from any other client). "Fix:" marks places where Hearth must do better than the reference app.

## 1. Engine
- One shared `AudioPlayer` (@MainActor, @Observable) owning at most one active *playback run* (current item, tracks, chapters, queue, sleep timer, session reporter). Each run gets a UUID; callbacks from stale runs are ignored. Only one start at a time.
- Implemented with `AVQueuePlayer`; disable external video playback; audio AirPlay via system route.
- **Start sequence**
  1. If item is currently downloading → error `.downloadInProgress` (UI offers "cancel download & play").
  2. Background task during startup.
  3. Online: open server session (`POST api/items/{id}/play[/episode]`, see API spec) → tracks, chapters, startTime, session id (persist id in "open sessions").
  4. Fallback (offline / failure): start = local progress (0 if finished); smart rewind: if last update ≥ 10 min ago → −30 s.
  5. Downloaded → local file tracks & stored chapters replace server ones (session still opened when online).
  6. Episodes: if server chapters empty, parse description timestamps (`(H:)MM:SS title` at line starts, optionally in parentheses). Fix: don't wipe server chapters with an empty parse result.
  7. Sort tracks/chapters by offset; mark item "in use" (download lock).
  8. Seek to start, publish state.
  9. Rate: item rate → grouping rate (collection started from > series > podcast) → global default.
  10. Play. Generate Up Next. Apply auto sleep timer. Remember "last played item" (shared defaults, for resume pill/widgets).
- **Multi-track timeline**: total = last.offset+last.duration. Load player items from current track to end. Streaming URL = host + contentUrl with custom headers + `Authorization: Bearer` via `AVURLAsset` options `"AVURLAssetHTTPHeaderFieldsKey"`. Seek(T): clamp ≥0; ≥ total → finish item; same track → seek in track; later loaded track → advance; else rebuild queue from that track. Seek precision ~ms. "Busy" counter while seeking.
- Track end → advance index; last track end → item finished.
- Token refresh / connection change → rebuild player items with fresh headers, seek back.
- Periodic time observer (~0.5 s): buffering check, current time = track offset + item time, active chapter, time in chapter, reporter tick, publish.
- Chapter-relative progress setting (`chapterRelativeProgress`, default on): scrubber & lock screen use chapter bounds.
- Buffering: item not ready or not likely to keep up.
- **Audio session**: `.playback`, mode `.spokenAudio`, policy `.longFormAudio`. Activate on play. Interruption began → pause (remember). Ended + shouldResume → play. Route change `oldDeviceUnavailable` (headphones unplugged) → pause (Fix: reflect state). Track current output route (name + port type icon: AirPods/AirPods Pro/Max, HomePod, Apple TV, AirPlay, Bluetooth, headphones, car, speaker).
- Observe `AVPlayer.timeControlStatus`/rate to keep `isPlaying` truthful (Fix).
- **Remote command center**: play, pause, toggle, changePlaybackPosition (chapter-relative; disabled if seek bar locked), skipBackward/skipForward (configured intervals, live updated), nextTrack/previousTrack → next/previous **chapter** (Hearth choice; setting `remoteNextPreviousSkipsChapters` default on, else skip intervals), bookmark command, changePlaybackRate (preset rates), stop. Fix: seekForward/Backward handle begin/end (ignore end).
- **Now Playing**: external content id = item id, title = chapter title (if chapter) else item name; album = item name / podcast name; artist = authors; artwork (large cover); duration/elapsed chapter-relative; chapter count/number; rate & default rate; queue index/count; playback state (interrupted while buffering).
- **Rate**: changes apply immediately; every change is saved as that item's rate.
- **Volume**: system volume via `MPVolumeView`; player volume only used for sleep timer fade.
- **Hearth extras**: "Voice boost" (loudness via `AVAudioMix`/`audioTimePitchAlgorithm .timeDomain` is fine; optional), pitch-corrected rates via `.timeDomain`/`.spectral` algorithm.

## 2. Queue
- Two tiers: **Queue** (user; reorder/remove/clear) and **Up Next** (generated; remove/clear/promote to queue).
- Item ends: first Queue item, else first Up Next, else stop. Natural finish: finalize at full duration, clear last-played, run auto-download hook (delete if `removeFinishedDownloads`, schedule next downloads).
- Jump to queue item i: drop items before i, finalize current (not finished), start it. Jump to Up Next i: clear Queue, drop before i.
- "Play next" (insert at front) **and** "Add to queue" (append) – Hearth adds play next.
- Finished items are pruned from both tiers.
- Fix: persist & restore queue across launches.
- **Up Next generation** (when empty & `generateUpNext` on; clearing disables regeneration for this run): origin (series/podcast/collection screen) > podcast strategy > series strategy. Strategies per grouping: default / listenNow / disabled (Fix: implement listenNow = remaining Listen Now items). Series → unfinished books after current in series order. Collection → unfinished items after current. Podcast → episodes filtered/sorted per saved podcast settings minus current. Header shows source.
- Entry points: Play (toggles if already current), Play next, Add to queue (starts if idle), Start grouping (first eligible item), timestamps/chapters/bookmarks on detail screens (start at time), Resume pill (last played).

## 3. Sessions & progress
- Reporter: time listened = wall-clock while playing; deltas per report. Report on play/pause, every >30 s (first after ~3 s), forced on finalize. Online+session → `session/{id}/sync`, else/fail → local session record (accumulate). Always update local progress.
- Finalize (item end/switch/stop/app exit): forced report, mark local session eligible, `session/{id}/close`, remove from open-sessions. Finished → currentTime = duration.
- Upload local sessions on launch/online (`session/local`). Fix: close stale open sessions on launch.
- Mark finished on currently playing item → seek to end (normal finish flow).
- Listened today: server sessions since midnight + local + current unreported. Refresh on activate/midnight. Daily goal default 30 min.

## 4. Sleep timer
- Modes: `.duration(deadline, original)`, `.chapters(remaining, original)`; "end of chapter" = chapters(1).
- Duration: paused time doesn't count (deadline shifts by pause length). Fade-out last 10 s (`sleepTimerFadeOut`, default on) linear volume. Expiry: pause, clear, restore volume, remember expiry (timer+date), smart rewind 10 s (not before chapter start).
- Chapters: decrement when chapter index advances by exactly one during playback; at ≤1 at boundary → pause/expire. Fix: works even if chapter-relative progress disabled. Optionally fade during final 10 s of the chapter.
- Set via player menu (End of chapter, presets 5,10,15,20,25,30,45,60,75,90 min; active: −/+ 1 min or 1 chapter, Extend, Cancel), chapter list swipe "Sleep at end of this chapter", Siri/Shortcuts, Live Activity, Control Center control, watch.
- Extend: `extendByPrevious` (default on) → original amount; else `extendInterval` (default 20 min) / `extendChapters` (default 1, 1–42).
- Shake to extend (`shakeExtendsSleepTimer`, default off; CoreMotion/`motionEnded`). Play-to-extend (`playExtendsSleepTimer`, default off): play within 10 s after expiry restores & extends.
- Auto-enable: item saved timer → grouping saved timer (collection > series > podcast); options disabled / presets / 1,2,3,5,7,10 chapters.
- Live Activity while timer active (see §7).

## 5. Playback speed
- Presets default 0.9, 1.0, 1.3, 1.6, 2.0 (editable 0.25–4.0 in 0.05; ≥1 remains). Default rate 1.0. Fine steps up/down 0.1 (0.05–0.5).
- Rate button: tap cycles presets; menu with presets + −/+.
- Per item (auto-saved), per grouping (configure sheet, only if ≠ default).
- Remaining times shown divided by rate (Fix: consistently).
- Siri: percentage 25–400.

## 6. Chapters, bookmarks, skip, smart rewind
- Chapter list in player (auto-scroll to current; past dimmed; swipe "sleep at end of chapter"; preview "ends at <clock>").
- Episodes: description with tappable timestamps (`hearth://seek/<seconds>` internal links).
- Scrubber: chapter-relative; drag acceleration (velocity <600 → 1×, <1000 → 2×, else 3×; release fling +10%); `lockSeekBar` disables; trailing label toggles total/remaining (persisted). Optional total-progress slider replacing volume (`replaceVolumeWithTotalProgress`, default off).
- Bookmarks (audiobooks): tap → note prompt (empty = quick), long-press → quick bookmark (note = formatted date/time). Also lock screen, CarPlay, Siri, widget, watch. List in player above chapters (tap seeks, swipe deletes, edit note).
- Skip intervals back/forward: 5,10,15,30,45,60,75,90 s (default 15 back / 30 forward). Tap combining (0.3 s first, 0.7 s more) with running total badge. Long-press back → chapter start; forward → next chapter.
- Smart rewind (`smartRewind`, default on): resume after pause > 30 s → −10 s (≥ chapter start); pause > 10 min → −30 s; sleep timer expiry → −10 s; cold start fallback as §1.

## 7. System integration
### App Intents / Shortcuts (tile color: orange)
Intents: Play item (any entity; series/podcast → next eligible), Play audiobook (books schema), Play podcast, Resume, Pause, Toggle, Skip back/forward (optional seconds), Next/Previous chapter, Set sleep timer (amount+unit seconds/minutes/hours/chapters), Extend / Cancel sleep timer, Set playback speed (%), Create bookmark (optional note), Now playing, Open item, Listen Now (returns items), Search (query, include server), Set finished, Download / Remove download, Check for new downloads, Toggle offline mode.
Entities: Item (id, title, authors, description, genres, added, released, URL, thumbnail), Audiobook (+ narrators, series, explicit, abridged), Podcast (+episode counts), Episode. `EntityStringQuery` + suggested = Listen Now. `IndexedEntity` for Spotlight. Donate on play; delete donations when finished.
App Shortcuts phrases (EN + DE) e.g. "Play \(\.$audiobook) in \(.applicationName)", "Resume \(.applicationName)", "Set a sleep timer in \(.applicationName)".
Use AppIntents `AudioPlaybackIntent` for playback intents so they run in background from widgets/controls.

### Widgets (WidgetKit extension; data via app-group shared container)
- **Play widget** (configurable item; systemSmall, systemMedium, accessoryCircular, accessoryRectangular): cover, name, progress-filled play/pause (interactive), skip back while playing, downloaded badge, bookmark button. Fallback first Listen Now item. Tap opens item.
- **Listen Now** (systemMedium 2 rows, systemLarge 6 rows, iPad systemExtraLarge): rows with play buttons.
- **Listened Today** (accessoryCircular gauge, accessoryRectangular, systemSmall ring): minutes vs goal (Fix: use real goal).
- **Control Center / Lock Screen controls** (iOS 18+ `ControlWidget`): Play/Pause toggle, Skip back, Skip forward, Sleep timer (toggle), Open Hearth search.
- The app must write shared snapshot (now playing item, isPlaying, progress, listen now items with cover thumbnails, listened today, goal) and call `WidgetCenter.reloadAllTimelines()` / `ControlCenter.shared.reloadAllControls()` (Fix: actually write it).
- **Live Activity** (ActivityKit): sleep timer (lock screen + Dynamic Island compact/minimal/expanded; Extend/Cancel or −/+ chapter buttons; paused state shows resume). Optional "Download progress" Live Activity for large downloads.

### Spotlight, Handoff, quick actions, URLs
- Core Spotlight indexing of audiobooks/podcasts (+ downloaded items) via BGProcessingTask; re-index after 21 days; tapping a Spotlight result opens the item (Fix).
- `NSUserActivity` on detail screens (`<bundle>.item` type, webpageURL = ABS web page) for Handoff & Siri suggestions; continuing navigates.
- Home screen quick actions: Search + top 3 Listen Now items (play them directly — Fix).
- URL scheme `hearth://`: `hearth://oauth` (login callback), `hearth://item/<identifier>`, `hearth://play/<identifier>`, `hearth://search?q=`, `hearth://seek/<seconds>` (internal).

### CarPlay (CPTemplateApplicationScene)
- No connection → "Sign in on your iPhone".
- Tabs: Listen Now (Siri playback assistant cell; sections Listen Now, downloaded audiobooks, downloaded episodes grouped by podcast) + chosen libraries (home shelves; podcast libs: list of podcasts → episodes) + "Other libraries" + Search? (no, CarPlay audio has no keyboard) . Max 5 tabs.
- Rows: title, "authors • narrators", cover, progress, now-playing indicator, downloaded accessory. Tap = play / toggle.
- Now Playing template: rate button (cycles), bookmark (books), next item (when queue). Up Next button → queue list. Album/artist button → chapter list (books) or podcast episodes.
- Fix: everything populated (no stubs).

### Siri media intent
`INPlayMediaIntent` handled in-app (iOS 26 still supports via App Intents `PlayMediaIntent`? Prefer App Intents; add `INPlayMediaIntent` handler only if needed). Upcoming media suggestions from Listen Now.

## 8. watchOS (Hearth addition)
Standalone watch app (watchOS 26) + phone companion via WatchConnectivity.
- Connections synced from iPhone (WatchConnectivity transfer of connection + tokens) or iCloud Keychain; can also play directly from server over Wi-Fi/LTE.
- Screens: Now Playing (system `NowPlayingView` for controlling phone playback or watch-local playback), Listen Now, Libraries → Audiobooks / Podcasts / Series lists, item detail (play, download to watch), Downloads, Settings (speed, skip intervals).
- Local playback on watch requires `AVAudioSession` `.longFormAudio` route sharing policy (Bluetooth headphones), `activate(options:)`.
- Downloads to watch via `URLSession` background session on watch (or phone transfer via `WCSession.transferFile`).
- Remote control mode: control iPhone playback (play/pause/skip/sleep timer/speed/bookmark) through WatchConnectivity messages when phone is playing.
- Complications/Smart Stack widgets (WidgetKit on watchOS): Listened today gauge, Now playing / resume.
- Progress sync uses the same HearthData progress engine.

## Settings affecting playback (defaults)
`defaultPlaybackRate`=1.0, `playbackRatePresets`=[0.9,1,1.3,1.6,2], `playbackRateStepUp/Down`=0.1, `sleepTimerPresets`=[5,10,15,20,25,30,45,60,75,90]min, `sleepTimerExtendByPrevious`=true, `sleepTimerExtendInterval`=20min, `sleepTimerExtendChapters`=1, `sleepTimerFadeOut`=true, `shakeExtendsSleepTimer`=false, `playExtendsSleepTimer`=false, `chapterRelativeProgress`=true, `smartRewind`=true, `generateUpNext`=true, `skipBackwardInterval`=15, `skipForwardInterval`=30, `lockSeekBar`=false, `replaceVolumeWithTotalProgress`=false, `remoteNextPreviousSkipsChapters`=true, `removeFinishedDownloads`=true, `allowCellularDownloads`=false, `dailyGoalMinutes`=30.
