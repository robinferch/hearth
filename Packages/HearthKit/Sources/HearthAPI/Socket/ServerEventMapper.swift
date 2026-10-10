import Foundation
import HearthModel
import os

/// Translates raw Socket.IO events into `ServerEvent`s and broadcasts them.
struct ServerEventMapper: Sendable {
    let converter: PayloadConverter
    let resolver: LibraryResolver
    let executor: RequestExecutor
    let broadcaster: EventBroadcaster<ServerEvent>

    private static let logger = Logger.api(ServerEventMapper.self)

    func handle(_ event: SocketIOClient.Event) async {
        switch event {
        case .connected:
            broadcaster.yield(.connected)
        case .disconnected:
            broadcaster.yield(.disconnected)
        case .event(let name, let payload):
            for mapped in await map(name: name, payload: payload) {
                broadcaster.yield(mapped)
            }
        }
    }

    func map(name: String, payload: Data?) async -> [ServerEvent] {
        switch name {
        case "user_item_progress_updated":
            guard let event = decode(ProgressUpdatedEventPayload.self, payload) else { return [] }
            await resolver.resolve([event.data.libraryItemID])
            guard let progress = converter.progress(event.data) else { return [] }
            return [.progressUpdated(progress)]

        case "item_updated", "items_updated":
            let items = decodeItems(payload)
            guard !items.isEmpty else { return [] }
            await executor.invalidateCache()
            return items.map { .itemUpdated(identifier(of: $0)) }

        case "item_added", "items_added":
            let items = decodeItems(payload)
            guard !items.isEmpty else { return [] }
            await executor.invalidateCache()
            var seen = Set<String>()
            return items.compactMap { item in
                let id = identifier(of: item)
                guard seen.insert(id.libraryID).inserted else { return nil }
                return .itemAdded(id.library)
            }

        case "item_removed":
            guard let reference = decode(ItemReferencePayload.self, payload) else { return [] }
            await executor.invalidateCache()
            let entry = converter.directory.entry(for: reference.id)
            let libraryID = reference.libraryID ?? entry?.libraryID ?? ""
            let kind: ItemIdentifier.Kind = entry?.isPodcast == true ? .podcast : .audiobook
            return [.itemRemoved(converter.identifier(kind, library: libraryID, primary: reference.id))]

        case "user_updated":
            return [.userUpdated]

        default:
            return []
        }
    }

    private func identifier(of item: LibraryItemPayload) -> ItemIdentifier {
        let libraryID = item.libraryID ?? converter.directory.entry(for: item.id)?.libraryID ?? ""
        converter.directory.register(itemID: item.id, libraryID: libraryID, isPodcast: item.isPodcast)
        return converter.identifier(item.isPodcast ? .podcast : .audiobook, library: libraryID, primary: item.id)
    }

    private func decodeItems(_ payload: Data?) -> [LibraryItemPayload] {
        guard let payload else { return [] }
        return (try? JSONDecoder.api.decode(OneOrMany<LibraryItemPayload>.self, from: payload))?.values ?? []
    }

    private func decode<T: Decodable>(_ type: T.Type, _ payload: Data?) -> T? {
        guard let payload else { return nil }
        do {
            return try JSONDecoder.api.decode(T.self, from: payload)
        } catch {
            Self.logger.debug("Undecodable socket payload for \(String(describing: T.self), privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
