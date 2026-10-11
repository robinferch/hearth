import AppIntents
import HearthData
import HearthIntents
import HearthModel
import HearthPlayback
import OSLog

/// Donates "play" intents when an item starts (Siri suggestions, Shortcuts) and removes them once the item
/// is finished. Also remembers the last sleep timer duration for the Control Center control.
@MainActor
final class SiriDonations {
    static let shared = SiriDonations()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "SiriDonations")
    private var tokens: [any NSObjectProtocol] = []

    private init() {}

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AudioPlayer.itemStartedNotification, object: nil, queue: .main) { notification in
            guard let id = AudioPlayer.itemID(from: notification) else { return }
            Task { @MainActor in await SiriDonations.shared.donatePlay(id) }
        })
        tokens.append(center.addObserver(forName: AudioPlayer.itemFinishedNotification, object: nil, queue: .main) { notification in
            guard let id = AudioPlayer.itemID(from: notification) else { return }
            Task { @MainActor in await SiriDonations.shared.deleteDonations(for: id) }
        })
        tokens.append(center.addObserver(forName: AudioPlayer.sleepTimerChangedNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SleepTimerActions.remember(AudioPlayer.shared.sleepTimer) }
        })
    }

    private func donatePlay(_ id: ItemIdentifier) async {
        guard let item = try? await HearthData.shared.items.playable(id) else { return }
        let image = await HearthData.shared.images.imageData(for: id, size: .tiny)
        do {
            switch item {
            case .audiobook(let audiobook):
                try await IntentDonationManager.shared.donate(intent: PlayAudiobookIntent(audiobook: AudiobookEntity(audiobook, imageData: image)))
            case .episode(let episode):
                try await IntentDonationManager.shared.donate(intent: PlayEpisodeIntent(episode: EpisodeEntity(episode, imageData: image)))
            }
            Self.logger.debug("Donated play intent for \(id.description, privacy: .public)")
        } catch {
            Self.logger.notice("Donating play intent failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deleteDonations(for id: ItemIdentifier) async {
        let identifier = id.description
        let predicates: [IntentDonationMatchingPredicate] = [
            .entityIdentifier(EntityIdentifier(for: AudiobookEntity.self, identifier: identifier)),
            .entityIdentifier(EntityIdentifier(for: EpisodeEntity.self, identifier: identifier)),
            .entityIdentifier(EntityIdentifier(for: ItemEntity.self, identifier: identifier)),
        ]
        for predicate in predicates {
            do {
                try await IntentDonationManager.shared.deleteDonations(matching: predicate)
            } catch {
                Self.logger.notice("Deleting donations failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
