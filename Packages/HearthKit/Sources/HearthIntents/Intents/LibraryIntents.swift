import AppIntents
import Foundation
import HearthData
import HearthModel
import HearthPlayback

// MARK: - Navigation

/// Opens an item in Hearth.
public struct OpenItemIntent: OpenIntent {
    public static let title = LocalizedStringResource("Open Item", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Opens an audiobook, podcast, episode, series or person in Hearth.", table: "System"))
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: LocalizedStringResource("Item", table: "System"))
    public var target: ItemEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)", table: "System")
    }

    public init() {}

    public init(target: ItemEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentNavigator.navigate(.open(try IntentSupport.identifier(target.id)))
        return .result()
    }
}

/// Opens the search screen (Control Center control, Shortcuts).
public struct OpenSearchIntent: AppIntent {
    public static let title = LocalizedStringResource("Search in Hearth", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Opens the search screen.", table: "System"))
    public static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: LocalizedStringResource("Search Term", table: "System"))
    public var query: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        IntentNavigator.navigate(.search(query))
        return .result()
    }
}

// MARK: - Queries

public struct ListenNowIntent: AppIntent {
    public static let title = LocalizedStringResource("Get Listen Now", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Returns the audiobooks and episodes you are listening to.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        try IntentSupport.prepare()
        let items = await EntitySource.listenNowItems()
        let images = await EntitySupport.imageData(for: items.map(\.id))
        return .result(value: items.map { ItemEntity($0, imageData: images[$0.id]) })
    }
}

public struct SearchItemsIntent: AppIntent {
    public static let title = LocalizedStringResource("Search Library", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Searches your libraries for audiobooks, podcasts, episodes, series and people.", table: "System"))

    @Parameter(title: LocalizedStringResource("Search Term", table: "System"))
    public var query: String

    @Parameter(title: LocalizedStringResource("Include Server", table: "System"), description: LocalizedStringResource("Search on your servers, not only in downloads.", table: "System"), default: true)
    public var includeServer: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)", table: "System") {
            \.$includeServer
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> {
        try IntentSupport.prepare()
        let results = await EntitySource.search(query, downloadsOnly: !includeServer)
        var items = [AnyItem]()
        items += results.audiobooks.map(AnyItem.audiobook)
        items += results.podcasts.map(AnyItem.podcast)
        items += results.episodes.map(AnyItem.episode)
        items += results.series.map(AnyItem.series)
        items += results.authors.map(AnyItem.person)
        items += results.narrators.map(AnyItem.person)
        let images = await EntitySupport.imageData(for: items.prefix(50).map(\.id))
        return .result(value: items.map { ItemEntity($0, imageData: images[$0.id]) })
    }
}

// MARK: - Item state

public struct SetFinishedIntent: AppIntent {
    public static let title = LocalizedStringResource("Mark as Finished", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Marks an audiobook or episode as finished or unfinished.", table: "System"))

    @Parameter(title: LocalizedStringResource("Item", table: "System"))
    public var item: ItemEntity

    @Parameter(title: LocalizedStringResource("Finished", table: "System"), default: true)
    public var finished: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$item) as finished: \(\.$finished)", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try IntentSupport.prepare()
        let id = try IntentSupport.identifier(item.id)
        guard id.isPlayable else { throw HearthIntentError.notPlayable }
        do {
            try await AudioPlayer.shared.setFinished(id, finished: finished)
        } catch {
            throw IntentSupport.wrap(error)
        }
        return .result()
    }
}

// MARK: - Downloads

public struct DownloadItemIntent: AppIntent {
    public static let title = LocalizedStringResource("Download Item", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Downloads an audiobook or episode for offline listening.", table: "System"))

    @Parameter(title: LocalizedStringResource("Item", table: "System"))
    public var item: ItemEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$item)", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try IntentSupport.prepare()
        let id = try IntentSupport.identifier(item.id)
        guard id.isPlayable else { throw HearthIntentError.notPlayable }
        do {
            try await HearthData.shared.downloads.download(id)
        } catch {
            throw IntentSupport.wrap(error)
        }
        return .result()
    }
}

public struct RemoveDownloadIntent: AppIntent {
    public static let title = LocalizedStringResource("Remove Download", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Deletes the downloaded files of an audiobook or episode.", table: "System"))

    @Parameter(title: LocalizedStringResource("Item", table: "System"))
    public var item: ItemEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Remove the download of \(\.$item)", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let id = try IntentSupport.identifier(item.id)
        guard id.isPlayable else { throw HearthIntentError.notPlayable }
        await HearthData.shared.downloads.remove(id)
        return .result()
    }
}

public struct CheckForNewDownloadsIntent: AppIntent {
    public static let title = LocalizedStringResource("Check for New Downloads", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Runs your automatic download rules now.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try IntentSupport.prepare()
        await HearthData.shared.downloads.runAutoDownloads()
        return .result()
    }
}

public struct SetOfflineModeIntent: AppIntent {
    public static let title = LocalizedStringResource("Toggle Offline Mode", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Turns offline mode on or off. Leave the value empty to toggle it.", table: "System"))

    @Parameter(title: LocalizedStringResource("Offline", table: "System"))
    public var enabled: Bool?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let connections = HearthData.shared.connections
        let offline = enabled ?? !connections.isOffline
        await connections.setOffline(offline)
        let text = offline ? IntentSupport.text("Offline mode is on.") : IntentSupport.text("Offline mode is off.")
        return .result(dialog: IntentSupport.dialog(text))
    }
}
