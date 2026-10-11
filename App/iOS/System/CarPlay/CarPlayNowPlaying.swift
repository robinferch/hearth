import CarPlay
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import UIKit

/// Configures `CPNowPlayingTemplate.shared`: playback rate (cycles presets), bookmark (audiobooks), next item
/// (when the queue has items), Up Next list, and the album/artist button (chapters or podcast episodes).
@MainActor
final class CarPlayNowPlaying: NSObject, CPNowPlayingTemplateObserver {
    /// Weak: the shared Now Playing template (and its button handlers) outlive the controller after a disconnect.
    private weak var controller: CarPlayController?
    private var template: CPNowPlayingTemplate { .shared }
    private var signature: [Bool] = []

    init(controller: CarPlayController) {
        self.controller = controller
    }

    func start() {
        template.add(self)
        template.upNextTitle = String(localized: "Up Next", table: "System")
        signature = []
        update()
    }

    func stop() {
        template.remove(self)
    }

    /// Re-applies buttons when the item, queue or bookmark availability changes.
    func update() {
        let player = AudioPlayer.shared
        let hasNext = !player.queue.isEmpty || !player.upNext.isEmpty
        template.isUpNextButtonEnabled = hasNext
        template.isAlbumArtistButtonEnabled = player.currentItem != nil
        let newSignature = [player.canCreateBookmark, hasNext]
        guard newSignature != signature else { return }
        signature = newSignature

        var buttons: [CPNowPlayingButton] = [
            CPNowPlayingPlaybackRateButton { _ in
                AudioPlayer.shared.cyclePlaybackRate()
            },
        ]
        if player.canCreateBookmark, let image = UIImage(systemName: "bookmark") {
            buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                Task { await self?.createBookmark() }
            })
        }
        if hasNext, let image = UIImage(systemName: "forward.end") {
            buttons.append(CPNowPlayingImageButton(image: image) { _ in
                Task { await AudioPlayer.shared.advance() }
            })
        }
        template.updateNowPlayingButtons(buttons)
    }

    private func createBookmark() async {
        do {
            try await AudioPlayer.shared.createBookmark()
        } catch {
            controller?.showError(error)
        }
    }

    // MARK: CPNowPlayingTemplateObserver

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            controller?.push(upNextTemplate())
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            let player = AudioPlayer.shared
            switch player.currentItem {
            case .audiobook(let audiobook):
                controller.push(chaptersTemplate(title: audiobook.name))
            case .episode(let episode):
                if let podcast = episode.id.podcastIdentifier {
                    controller.push(controller.groupingTemplate(podcast, title: episode.podcastName))
                }
            case nil:
                break
            }
        }
    }

    // MARK: Lists

    private func upNextTemplate() -> CPListTemplate {
        let player = AudioPlayer.shared
        var sections = [CPListSection]()
        // The list is a snapshot: rows look their item up when tapped (the queue may have moved on meanwhile).
        if !player.queue.isEmpty {
            sections.append(CPListSection(items: player.queue.map { item in
                queueRow(item) { [weak self] in await self?.playQueued(item.id) }
            }, header: String(localized: "Queue", table: "System"), sectionIndexTitle: nil))
        }
        if !player.upNext.isEmpty {
            sections.append(CPListSection(items: player.upNext.map { item in
                queueRow(item) { [weak self] in await self?.playQueued(item.id) }
            }, header: player.upNextSource ?? String(localized: "Up Next", table: "System"), sectionIndexTitle: nil))
        }
        let template = CPListTemplate(title: String(localized: "Up Next", table: "System"), sections: CarPlayController.limited(sections))
        template.emptyViewTitleVariants = [String(localized: "Nothing queued", table: "System")]
        return template
    }

    /// Jumps to a queue / Up Next item by identity; plays it directly when it left both lists.
    private func playQueued(_ id: ItemIdentifier) async {
        let player = AudioPlayer.shared
        if let index = player.queue.firstIndex(where: { $0.id == id }) {
            await player.jumpToQueueItem(at: index)
        } else if let index = player.upNext.firstIndex(where: { $0.id == id }) {
            await player.jumpToUpNextItem(at: index)
        } else if !player.isCurrent(id) {
            do {
                try await player.play(id)
            } catch {
                controller?.showError(error)
            }
        }
    }

    private func queueRow(_ item: AnyPlayableItem, action: @escaping @MainActor () async -> Void) -> CPListItem {
        let row = CPListItem(text: item.name, detailText: item.base.subtitleLine ?? item.base.authorLine, image: CarPlayRows.placeholder(for: item.id.kind), accessoryImage: nil, accessoryType: .none)
        row.playbackProgress = CGFloat(HearthData.shared.progress.progress(for: item.id)?.progress ?? 0)
        controller?.rows.loadImage(for: item.id, into: row)
        row.handler = { [weak controller] _, completion in
            Task {
                await action()
                controller?.showNowPlaying()
                completion()
            }
        }
        return row
    }

    private func chaptersTemplate(title: String) -> CPListTemplate {
        let player = AudioPlayer.shared
        let rate = max(player.playbackRate, 0.1)
        let rows = player.chapters.enumerated().map { index, chapter in
            let detail = HearthFormat.joined([chapter.start.clockFormatted, HearthFormat.duration(chapter.duration / rate)])
            let row = CPListItem(text: chapter.title, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .none)
            row.isPlaying = index == player.currentChapterIndex
            row.playingIndicatorLocation = .leading
            if let current = player.currentChapterIndex, index < current {
                row.playbackProgress = 1
            } else if index == player.currentChapterIndex, chapter.duration > 0 {
                row.playbackProgress = CGFloat((player.currentTime - chapter.start) / chapter.duration)
            }
            row.handler = { [weak controller] _, completion in
                Task {
                    await AudioPlayer.shared.seek(toChapter: chapter)
                    controller?.showNowPlaying()
                    completion()
                }
            }
            return row
        }
        let template = CPListTemplate(title: title, sections: CarPlayController.limited([CPListSection(items: rows)]))
        template.emptyViewTitleVariants = [String(localized: "No chapters", table: "System")]
        return template
    }
}
