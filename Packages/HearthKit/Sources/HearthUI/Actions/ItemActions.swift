import HearthData
import HearthModel
import SwiftUI

// MARK: - Modifiers

public extension View {
    /// Context menu (with preview), swipe actions and accessibility actions for a playable item.
    ///
    /// - Parameters:
    ///   - swipeActions: Adds leading/trailing swipe actions (only effective inside `List`).
    ///   - context: Hides redundant links (e.g. "View podcast" on the podcast page).
    func itemActions(for item: AnyPlayableItem, swipeActions: Bool = true, context: ItemActionContext = .standard) -> some View {
        modifier(ItemActionsModifier(item: item, swipeActions: swipeActions, context: context))
    }

    /// Context menu for non-playable items (podcasts, series, people, collections).
    func itemActions(for item: AnyItem) -> some View {
        modifier(GroupingActionsModifier(item: item))
    }
}

/// Where the item is shown, used to omit links to the current page.
public enum ItemActionContext: Hashable, Sendable {
    case standard
    case podcastPage
    case seriesPage
    case authorPage
    case listenNow
}

struct ItemActionsModifier: ViewModifier {
    let item: AnyPlayableItem
    let swipeActions: Bool
    let context: ItemActionContext

    @Environment(\.itemActionHandler) private var handler

    func body(content: Content) -> some View {
        content
            #if !os(watchOS)
            .contextMenu {
                ItemContextMenu(item: item, context: context)
            } preview: {
                ItemContextPreview(item: item)
            }
            #endif
            .modifier(SwipeActionsModifier(item: item, enabled: swipeActions))
            #if !os(macOS)
            .accessibilityAction(.magicTap) {
                guard handler.canPlay else { return }
                Task { await handler.play(item.id) }
            }
            #endif
            .accessibilityActions {
                if handler.canPlay {
                    Button(loc("Play")) { Task { await handler.play(item.id) } }
                    Button(loc("Add to queue")) { Task { await handler.addToQueue(item.id) } }
                }
                downloadAccessibilityAction
            }
    }

    @ViewBuilder
    private var downloadAccessibilityAction: some View {
        let status = ItemStatus.of(item.id)
        if status.isDownloaded {
            Button(loc("Remove download")) { Task { await handler.removeDownload(item.id) } }
        } else if !status.isDownloading {
            Button(loc("Download")) { Task { await handler.download(item.id) } }
        }
    }
}

private struct SwipeActionsModifier: ViewModifier {
    let item: AnyPlayableItem
    let enabled: Bool

    @Environment(\.itemActionHandler) private var handler
    @Environment(\.hearthAccent) private var accent

    func body(content: Content) -> some View {
        if enabled {
            let status = ItemStatus.of(item.id)
            content
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if handler.canPlay {
                        Button {
                            Task { await handler.play(item.id) }
                        } label: {
                            Label(loc("Play"), systemImage: "play.fill")
                        }
                        .tint(.hearthTint)
                        Button {
                            Task { await handler.addToQueue(item.id) }
                        } label: {
                            Label(loc("Add to queue"), systemImage: "text.badge.plus")
                        }
                        .tint(accent)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if status.isDownloaded || status.isDownloading {
                        Button(role: .destructive) {
                            Task {
                                if status.isDownloading {
                                    await handler.cancelDownload(item.id)
                                } else {
                                    await handler.removeDownload(item.id)
                                }
                            }
                        } label: {
                            Label(status.isDownloading ? loc("Cancel download") : loc("Remove download"), systemImage: "trash")
                        }
                        .tint(.red)
                    } else {
                        Button {
                            Task { await handler.download(item.id) }
                        } label: {
                            Label(loc("Download"), systemImage: "arrow.down.circle")
                        }
                        .tint(.blue)
                    }
                    Button {
                        Task { await handler.setFinished(item.id, !status.isFinished) }
                    } label: {
                        if status.isFinished {
                            Label(loc("Mark as unfinished"), systemImage: "arrow.uturn.backward.circle")
                        } else {
                            Label(loc("Mark as finished"), systemImage: "checkmark.circle")
                        }
                    }
                    .tint(status.isFinished ? .orange : .green)
                }
        } else {
            content
        }
    }
}

// MARK: - Menu

#if !os(watchOS)

/// The shared context menu for audiobooks and episodes. Usable directly inside `Menu { }` too.
public struct ItemContextMenu: View {
    let item: AnyPlayableItem
    let context: ItemActionContext

    @Environment(\.itemActionHandler) private var handler

    public init(item: AnyPlayableItem, context: ItemActionContext = .standard) {
        self.item = item
        self.context = context
    }

    public var body: some View {
        let id = item.id
        let status = ItemStatus.of(id)

        ControlGroup {
            if let url = handler.shareURL(id) {
                ShareLink(item: url) {
                    Label(loc("Share"), systemImage: "square.and.arrow.up")
                }
            }
            Button {
                handler.addTo(id)
            } label: {
                Label(loc("Add to…"), systemImage: "text.badge.plus")
            }
            downloadButton(status)
        }

        if handler.canPlay {
            Section {
                Button {
                    Task { await handler.play(id) }
                } label: {
                    if handler.isPlaying(id) {
                        Label(loc("Pause"), systemImage: "pause.fill")
                    } else {
                        Label(loc("Play"), systemImage: "play.fill")
                    }
                }
                Button {
                    Task { await handler.playNext(id) }
                } label: {
                    Label(loc("Play next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await handler.addToQueue(id) }
                } label: {
                    Label(loc("Add to queue"), systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }

        Section {
            if status.isFinished {
                Button {
                    Task { await handler.setFinished(id, false) }
                } label: {
                    Label {
                        Text(loc("Mark as unfinished"))
                        Text(HearthFormat.finished(status.progress?.finishedAt))
                    } icon: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                }
            } else {
                Button {
                    Task { await handler.setFinished(id, true) }
                } label: {
                    Label(loc("Mark as finished"), systemImage: "checkmark.circle")
                }
            }
            if status.progress != nil {
                Button(role: .destructive) {
                    Task { await handler.resetProgress(id) }
                } label: {
                    Label(loc("Reset progress"), systemImage: "arrow.counterclockwise")
                }
            }
            if status.isInProgress, status.progress?.hideFromContinueListening == false {
                Button {
                    Task { await handler.hideFromContinueListening(id) }
                } label: {
                    Label(loc("Hide from Continue Listening"), systemImage: "eye.slash")
                }
            }
        }

        Section {
            links
            if let openInNewWindow = handler.openInNewWindow {
                Button {
                    openInNewWindow(id)
                } label: {
                    Label(loc("Open in New Window"), systemImage: "macwindow.badge.plus")
                }
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ status: ItemStatus) -> some View {
        if status.isDownloading {
            Button(role: .destructive) {
                Task { await handler.cancelDownload(item.id) }
            } label: {
                Label(loc("Cancel download"), systemImage: "stop.circle")
            }
        } else if status.isDownloaded {
            Button(role: .destructive) {
                Task { await handler.removeDownload(item.id) }
            } label: {
                Label(loc("Remove download"), systemImage: "trash")
            }
        } else {
            Button {
                Task { await handler.download(item.id) }
            } label: {
                Label(loc("Download"), systemImage: "arrow.down.circle")
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        switch item {
        case .audiobook(let book):
            Button {
                handler.navigate(.item(book.id))
            } label: {
                Label(loc("View audiobook"), systemImage: "book.closed")
            }
            if context != .authorPage {
                linkGroup(title: loc("View author"), pluralTitle: loc("Authors"), systemImage: "person", names: book.authors) {
                    .author(name: $0, library: book.id.library)
                }
            }
            linkGroup(title: loc("View narrator"), pluralTitle: loc("Narrators"), systemImage: "waveform", names: book.narrators) {
                .narrator(name: $0, library: book.id.library)
            }
            if context != .seriesPage {
                let series = NavigationDestination.series(of: book)
                if series.count == 1, let first = series.first {
                    Button {
                        handler.navigate(first.destination)
                    } label: {
                        Label(loc("View series"), systemImage: "books.vertical")
                    }
                } else if series.count > 1 {
                    Menu {
                        ForEach(series, id: \.title) { entry in
                            Button(entry.title) { handler.navigate(entry.destination) }
                        }
                    } label: {
                        Label(loc("Series"), systemImage: "books.vertical")
                    }
                }
            }
        case .episode(let episode):
            Button {
                handler.navigate(.item(episode.id))
            } label: {
                Label(loc("View episode"), systemImage: "waveform.circle")
            }
            if context != .podcastPage, let podcast = episode.id.podcastIdentifier {
                Button {
                    handler.navigate(.item(podcast))
                } label: {
                    Label(loc("View podcast"), systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
    }

    @ViewBuilder
    private func linkGroup(title: String, pluralTitle: String, systemImage: String, names: [String], destination: @escaping (String) -> NavigationDestination) -> some View {
        if names.count == 1, let name = names.first {
            Button {
                handler.navigate(destination(name))
            } label: {
                Label {
                    Text(title)
                    Text(name)
                } icon: {
                    Image(systemName: systemImage)
                }
            }
        } else if names.count > 1 {
            Menu {
                ForEach(names, id: \.self) { name in
                    Button(name) { handler.navigate(destination(name)) }
                }
            } label: {
                Label(pluralTitle, systemImage: systemImage)
            }
        }
    }
}

// MARK: - Preview

/// Large context menu preview: cover + title + authors / narrators (book) or date, duration, description (episode).
public struct ItemContextPreview: View {
    let item: AnyPlayableItem

    public init(item: AnyPlayableItem) {
        self.item = item
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemImage(id: item.id, size: .regular, cornerRadius: 12)
                .frame(width: 260, height: 260)
            switch item {
            case .audiobook(let book):
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.name)
                        .hearthTitle(.title3)
                        .lineLimit(3)
                    if let authors = book.authorLine {
                        Text(authors)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !book.narrators.isEmpty {
                        Text(String(localized: "Read by \(book.narrators.formatted(.list(type: .and)))", bundle: .module))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .episode(let episode):
                VStack(alignment: .leading, spacing: 4) {
                    Text(HearthFormat.joined([episode.publishedAt.map { HearthFormat.releaseDate($0) }, HearthFormat.duration(episode.duration)]))
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                    Text(episode.name)
                        .hearthTitle(.headline)
                        .lineLimit(3)
                    if let description = HearthFormat.plainText(fromHTML: episode.descriptionHTML) {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                }
            }
        }
        .frame(width: 260)
        .padding(16)
    }
}

#endif

// MARK: - Groupings

struct GroupingActionsModifier: ViewModifier {
    let item: AnyItem

    @Environment(\.itemActionHandler) private var handler

    func body(content: Content) -> some View {
        #if os(watchOS)
        content
        #else
        content.contextMenu {
            if let url = handler.shareURL(item.id) {
                ShareLink(item: url) {
                    Label(loc("Share"), systemImage: "square.and.arrow.up")
                }
            }
            if handler.canPlay, [.series, .podcast, .collection, .playlist].contains(item.id.kind) {
                Button {
                    Task { await handler.playGrouping(item.id) }
                } label: {
                    Label(loc("Play"), systemImage: "play.fill")
                }
            }
            Button {
                handler.navigate(.item(item.id))
            } label: {
                Label(String(localized: "View \(item.id.kind.localizedName)", bundle: .module), systemImage: item.id.kind.systemImage)
            }
            if let openInNewWindow = handler.openInNewWindow {
                Button {
                    openInNewWindow(item.id)
                } label: {
                    Label(loc("Open in New Window"), systemImage: "macwindow.badge.plus")
                }
            }
        }
        #endif
    }
}
