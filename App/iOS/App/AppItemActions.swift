import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Builds the app's `ItemActionHandler`: playback via `AudioPlayer`, data via `HearthData`,
/// warnings via `AlertCenter`, navigation via `Navigator`.
@MainActor
enum AppItemActions {
    static func handler(navigator: Navigator, alerts: AlertCenter, player: PlayerPresentation, openWindow: OpenWindowAction?) -> ItemActionHandler {
        let data = HearthData.shared
        let audio = AudioPlayer.shared

        var handler = ItemActionHandler(canPlay: true)
        handler.play = { id in
            await play(id, alerts: alerts, player: player)
        }
        handler.playGrouping = { id in
            do {
                try await audio.play(grouping: id)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.playNext = { id in
            do {
                try await audio.playNext(id)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.addToQueue = { id in
            do {
                try await audio.addToQueue(id)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.setFinished = { id, finished in
            do {
                try await audio.setFinished(id, finished: finished)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.resetProgress = { id in
            do {
                try await data.progress.reset(id)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.hideFromContinueListening = { id in
            do {
                try await data.progress.hideFromContinueListening(id)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
        handler.download = { id in
            await download(id, alerts: alerts)
        }
        handler.removeDownload = { id in
            removeDownload(id, alerts: alerts)
        }
        handler.cancelDownload = { id in
            await data.downloads.cancel(id)
        }
        handler.addTo = { id in
            // Scene sheets are presented below the full-screen player (e.g. from its queue).
            player.isExpanded = false
            navigator.sheet = .addTo(id)
        }
        handler.navigate = { destination in
            player.isExpanded = false
            if navigator.sheet == .listenNow {
                navigator.sheet = nil
            }
            navigator.push(destination)
        }
        if let openWindow {
            handler.openInNewWindow = { id in
                openWindow(value: id)
            }
        }
        handler.isCurrent = { id in
            audio.isCurrent(id)
        }
        handler.isPlaying = { id in
            audio.isCurrent(id) && audio.isPlaying
        }
        return handler
    }

    // MARK: Play

    /// Plays `id` (from `time` if given, with `origin` for Up Next). While the item is downloading, offers to
    /// cancel the download and stream it – keeping the start time and origin.
    static func play(_ id: ItemIdentifier, origin: PlaybackOrigin = .none, at time: TimeInterval? = nil, alerts: AlertCenter, player: PlayerPresentation) async {
        let audio = AudioPlayer.shared
        let wasCurrent = audio.isCurrent(id)
        do {
            try await audio.play(id, origin: origin, at: time)
            if !wasCurrent {
                player.itemStarted()
            }
        } catch PlaybackError.downloadInProgress {
            alerts.present(WarningAlert(
                title: String(localized: "Item is downloading"),
                message: String(localized: "This item is still downloading. Cancel the download and stream it instead?"),
                actions: [
                    .init(title: String(localized: "Cancel Download & Play"), role: .destructive) {
                        await HearthData.shared.downloads.cancel(id)
                        do {
                            try await AudioPlayer.shared.play(id, origin: origin, at: time)
                            player.itemStarted()
                        } catch {
                            alerts.fail(error)
                        }
                    },
                    .init(title: String(localized: "Cancel"), role: .cancel),
                ]
            ))
        } catch {
            alerts.fail(error, title: String(localized: "Playback failed"))
        }
    }

    // MARK: Downloads

    static func download(_ id: ItemIdentifier, alerts: AlertCenter) async {
        let start: @MainActor () async -> Void = {
            do {
                try await HearthData.shared.downloads.download(id)
                alerts.succeed()
            } catch {
                alerts.fail(error, title: String(localized: "Download failed"))
            }
        }
        if AudioPlayer.shared.isCurrent(id) {
            alerts.present(WarningAlert(
                title: String(localized: "Download playing item?"),
                message: String(localized: "This item is playing. Playback will switch to the downloaded files once the download finishes."),
                actions: [
                    .init(title: String(localized: "Download"), perform: start),
                    .init(title: String(localized: "Cancel"), role: .cancel),
                ]
            ))
        } else {
            await start()
        }
    }

    static func removeDownload(_ id: ItemIdentifier, alerts: AlertCenter) {
        let downloads = HearthData.shared.downloads
        if AudioPlayer.shared.isCurrent(id) {
            alerts.present(WarningAlert(
                title: String(localized: "Item is playing"),
                message: String(localized: "Stop playback before removing the download."),
                actions: [
                    .init(title: String(localized: "Stop & Remove"), role: .destructive) {
                        await AudioPlayer.shared.stop()
                        await downloads.remove(id)
                        alerts.succeed()
                    },
                    .init(title: String(localized: "Cancel"), role: .cancel),
                ]
            ))
            return
        }
        if downloads.isAutomaticallyDownloaded(id) {
            var actions: [WarningAlert.Action] = [
                .init(title: String(localized: "Remove Download"), role: .destructive) {
                    await downloads.remove(id)
                    alerts.succeed()
                },
            ]
            if let grouping = id.podcastIdentifier, downloads.autoDownloadRule(for: grouping) != .disabled {
                actions.append(.init(title: String(localized: "Remove Rule & Download"), role: .destructive) {
                    await downloads.setAutoDownloadRule(.disabled, for: grouping)
                    await downloads.remove(id)
                    alerts.succeed()
                })
            }
            actions.append(.init(title: String(localized: "Cancel"), role: .cancel))
            alerts.present(WarningAlert(
                title: String(localized: "Automatically downloaded"),
                message: String(localized: "This item was downloaded by an automatic download rule and may be downloaded again."),
                actions: actions
            ))
            return
        }
        Task {
            await downloads.remove(id)
            alerts.succeed()
        }
    }
}
