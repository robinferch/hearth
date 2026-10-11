import AVFoundation
import Foundation
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import Observation
import OSLog
import WatchKit

/// What the watch is currently controlling.
enum PlaybackMode: Hashable {
    /// `AudioPlayer.shared` on the watch (Bluetooth audio).
    case local
    /// The iPhone's player via WatchConnectivity.
    case phone
}

/// A user-facing problem (shown as an alert by the root view).
struct WatchAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
}

/// Single entry point for the UI: reads either the local player or the phone's state and routes actions.
@MainActor
@Observable
final class WatchPlayer {
    static let shared = WatchPlayer()

    var alert: WatchAlert?
    /// While starting local playback (route picker, session).
    private(set) var isStarting = false

    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "WatchPlayer")

    private var local: AudioPlayer { .shared }
    private var phone: PhoneLink { .shared }

    private init() {}

    // MARK: Mode

    var mode: PlaybackMode? {
        if local.isActive { return .local }
        if phone.isPhoneActive { return .phone }
        return nil
    }

    var isActive: Bool { mode != nil }

    // MARK: State

    var itemID: ItemIdentifier? {
        switch mode {
        case .local: local.currentItem?.id
        case .phone: phone.state?.itemID
        case nil: nil
        }
    }

    var title: String {
        switch mode {
        case .local: local.currentItem?.name ?? ""
        case .phone: phone.state?.title ?? ""
        case nil: ""
        }
    }

    var subtitle: String? {
        switch mode {
        case .local:
            switch local.currentItem {
            case .audiobook(let audiobook): audiobook.authorLine
            case .episode(let episode): episode.podcastName
            case nil: nil
            }
        case .phone: phone.state?.subtitle
        case nil: nil
        }
    }

    var chapterTitle: String? {
        switch mode {
        case .local: local.currentChapter?.title
        case .phone: phone.state?.chapterTitle
        case nil: nil
        }
    }

    var chapters: [Chapter] {
        switch mode {
        case .local: local.chapters
        case .phone: phone.state?.chapters ?? []
        case nil: []
        }
    }

    var currentChapterIndex: Int? {
        switch mode {
        case .local: local.currentChapterIndex
        case .phone: phone.state?.chapterIndex
        case nil: nil
        }
    }

    var isPlaying: Bool {
        switch mode {
        case .local: local.isPlaying
        case .phone: phone.state?.isPlaying ?? false
        case nil: false
        }
    }

    var isBuffering: Bool {
        switch mode {
        case .local: local.isBuffering || local.isBusy || isStarting
        case .phone: phone.state?.isBuffering ?? false
        case nil: isStarting
        }
    }

    var playbackRate: Double {
        switch mode {
        case .local: local.playbackRate
        case .phone: phone.state?.playbackRate ?? 1
        case nil: 1
        }
    }

    var playbackRatePresets: [Double] {
        switch mode {
        case .phone: phone.state?.playbackRatePresets ?? AppSettings.shared.playbackRatePresets
        default: AppSettings.shared.playbackRatePresets
        }
    }

    var skipBackwardInterval: Int {
        mode == .phone ? (phone.state?.skipBackwardInterval ?? 15) : AppSettings.shared.skipBackwardInterval
    }

    var skipForwardInterval: Int {
        mode == .phone ? (phone.state?.skipForwardInterval ?? 30) : AppSettings.shared.skipForwardInterval
    }

    var sleepTimer: SleepTimerState? {
        switch mode {
        case .local: local.sleepTimer
        case .phone: phone.state?.sleepTimer
        case nil: nil
        }
    }

    func sleepTimerRemaining(at date: Date) -> TimeInterval? {
        switch mode {
        case .local: local.sleepTimerRemaining
        case .phone: phone.state?.sleepTimerRemaining(at: date)
        case nil: nil
        }
    }

    var canCreateBookmark: Bool {
        switch mode {
        case .local: local.canCreateBookmark
        case .phone: phone.state?.canCreateBookmark ?? false
        case nil: false
        }
    }

    var routeName: String? {
        switch mode {
        case .local: local.route.name
        case .phone: phone.state?.routeName
        case nil: nil
        }
    }

    var routeSymbol: String {
        switch mode {
        case .local: local.route.systemImage
        case .phone: phone.state?.routeSymbol ?? "iphone"
        case nil: "speaker.wave.2"
        }
    }

    func displayedTime(at date: Date) -> TimeInterval {
        switch mode {
        case .local: local.displayedTime
        case .phone: phone.state?.displayedTime(at: date) ?? 0
        case nil: 0
        }
    }

    var displayedDuration: TimeInterval {
        switch mode {
        case .local: local.displayedDuration
        case .phone: phone.state?.displayedDuration ?? 0
        case nil: 0
        }
    }

    func currentTime(at date: Date) -> TimeInterval {
        switch mode {
        case .local: local.currentTime
        case .phone: phone.state?.currentTime(at: date) ?? 0
        case nil: 0
        }
    }

    var duration: TimeInterval {
        switch mode {
        case .local: local.duration
        case .phone: phone.state?.duration ?? 0
        case nil: 0
        }
    }

    // MARK: Starting playback

    /// Plays an item on the watch. Activates the audio session first so the system can ask for Bluetooth
    /// headphones, and surfaces failures as alerts.
    func playLocally(_ id: ItemIdentifier, origin: PlaybackOrigin = .none, at time: TimeInterval? = nil) async {
        if local.isCurrent(id), time == nil {
            await toggleLocal()
            return
        }
        guard await prepareAudioRoute() else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            try await local.play(id, origin: origin, at: time)
            WKInterfaceDevice.current().play(.start)
            // Hand over: pause the phone if it was playing.
            if phone.state?.isPlaying == true {
                await phone.send(.pause)
            }
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    /// Starts an item on the iPhone.
    func playOnPhone(_ id: ItemIdentifier) async {
        if local.isPlaying {
            local.pause()
        }
        if await phone.send(.playItem(id, at: nil)) {
            WKInterfaceDevice.current().play(.start)
        }
    }

    /// Resumes the last played local item.
    func resumeLastPlayed() async {
        guard await prepareAudioRoute() else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            try await local.resumeLastPlayed()
        } catch {
            present(error)
        }
    }

    /// Activates the long-form audio session. On watchOS this presents the route picker when no Bluetooth
    /// output is connected; `false` when the user dismissed it or activation failed.
    private func prepareAudioRoute() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        do {
            let activated = try await AVAudioSession.sharedInstance().activate(options: [])
            if !activated {
                alert = WatchAlert(
                    title: String(localized: "Connect Headphones"),
                    message: String(localized: "To listen on Apple Watch, connect Bluetooth headphones or a speaker.")
                )
            }
            return activated
        } catch {
            logger.error("Activating the audio session failed: \(error.localizedDescription, privacy: .public)")
            alert = WatchAlert(
                title: String(localized: "Audio Unavailable"),
                message: String(localized: "Hearth couldn't use the audio output. Connect Bluetooth headphones and try again.")
            )
            return false
        }
        #endif
    }

    private func present(_ error: any Error) {
        logger.error("Playback failed: \(String(describing: error), privacy: .public)")
        WKInterfaceDevice.current().play(.failure)
        let message: String = switch error as? PlaybackError {
        case .downloadInProgress: String(localized: "This item is still downloading to your watch. Wait for the download to finish or cancel it.")
        case .some(let error): error.localizedDescription
        case nil: error.localizedDescription
        }
        alert = WatchAlert(title: String(localized: "Can't Play"), message: message)
    }

    // MARK: Transport

    func togglePlayPause() async {
        switch mode {
        case .local: await toggleLocal()
        case .phone: await phone.send(.togglePlayPause)
        case nil:
            if local.lastPlayedItemID != nil {
                await resumeLastPlayed()
            }
        }
    }

    private func toggleLocal() async {
        if local.isPlaying {
            local.pause()
        } else {
            guard await prepareAudioRoute() else { return }
            local.resume()
        }
    }

    func skipBackward() async {
        WKInterfaceDevice.current().play(.click)
        switch mode {
        case .local: await local.skipBackward()
        case .phone: await phone.send(.skipBackward(nil))
        case nil: break
        }
    }

    func skipForward() async {
        WKInterfaceDevice.current().play(.click)
        switch mode {
        case .local: await local.skipForward()
        case .phone: await phone.send(.skipForward(nil))
        case nil: break
        }
    }

    func nextChapter() async {
        switch mode {
        case .local: await local.nextChapter()
        case .phone: await phone.send(.nextChapter)
        case nil: break
        }
    }

    func previousChapter() async {
        switch mode {
        case .local: await local.previousChapter()
        case .phone: await phone.send(.previousChapter)
        case nil: break
        }
    }

    func seek(to chapter: Chapter) async {
        switch mode {
        case .local: await local.seek(toChapter: chapter)
        case .phone: await phone.send(.seekToChapter(chapter.id))
        case nil: break
        }
    }

    func seek(toDisplayedTime time: TimeInterval) async {
        switch mode {
        case .local: await local.seek(toDisplayedTime: time)
        case .phone: await phone.send(.seekToDisplayedTime(time))
        case nil: break
        }
    }

    func setPlaybackRate(_ rate: Double) async {
        let rate = min(4, max(0.25, (rate * 100).rounded() / 100))
        switch mode {
        case .local: local.setPlaybackRate(rate)
        case .phone: await phone.send(.setPlaybackRate(rate))
        case nil: break
        }
    }

    func setSleepTimer(_ preset: SleepTimerPreset) async {
        switch mode {
        case .local: local.setSleepTimer(preset)
        case .phone: await phone.send(.setSleepTimer(preset))
        case nil: break
        }
    }

    func sleepAtEnd(of chapter: Chapter) async {
        switch mode {
        case .local: local.setSleepTimer(endOf: chapter)
        case .phone: await phone.send(.sleepAtEndOfChapter(chapter.id))
        case nil: break
        }
    }

    func extendSleepTimer() async {
        switch mode {
        case .local: local.extendSleepTimer()
        case .phone: await phone.send(.extendSleepTimer)
        case nil: break
        }
    }

    func adjustSleepTimer(by delta: Int) async {
        switch mode {
        case .local: local.adjustSleepTimer(by: delta)
        case .phone: await phone.send(.adjustSleepTimer(delta))
        case nil: break
        }
    }

    func cancelSleepTimer() async {
        switch mode {
        case .local: local.cancelSleepTimer()
        case .phone: await phone.send(.cancelSleepTimer)
        case nil: break
        }
    }

    /// Quick bookmark at the current position. Returns `true` on success.
    @discardableResult
    func createBookmark() async -> Bool {
        let success: Bool
        switch mode {
        case .local:
            do {
                try await local.createBookmark()
                success = true
            } catch {
                logger.error("Creating a bookmark failed: \(error.localizedDescription, privacy: .public)")
                success = false
            }
        case .phone:
            success = await phone.send(.createBookmark(note: nil))
        case nil:
            success = false
        }
        WKInterfaceDevice.current().play(success ? .success : .failure)
        return success
    }

    func stop() async {
        switch mode {
        case .local: await local.stop()
        case .phone: await phone.send(.stop)
        case nil: break
        }
    }
}
