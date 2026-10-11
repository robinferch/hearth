import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Audiobook page: hero header, description, bookmarks, chapters, timeline, documents, details and
/// "more in series / by author / read by" shelves.
struct AudiobookDetailView: View {
    let id: ItemIdentifier

    @State private var model: AudiobookDetailModel

    init(id: ItemIdentifier) {
        self.id = id
        _model = State(initialValue: AudiobookDetailModel(id: id))
    }

    var body: some View {
        LoadStateView(model.state, retry: { await model.load() }) { book in
            AudiobookDetailContent(book: book, model: model)
        }
        .itemUserActivity(id, title: model.state.value?.name)
        .task { await model.loadIfNeeded() }
    }
}

@MainActor
@Observable
final class AudiobookDetailModel {
    let id: ItemIdentifier
    private(set) var state: LoadState<Audiobook> = .loading
    private(set) var details: PlayableItemDetails?
    private(set) var seriesShelves: [Shelf] = []
    private(set) var authorShelf: Shelf?
    private(set) var narratorShelf: Shelf?

    struct Shelf: Identifiable {
        var id: String { title }
        var title: String
        var destination: NavigationDestination?
        var books: [Audiobook]
    }

    init(id: ItemIdentifier) {
        self.id = id
    }

    var chapters: [Chapter] { details?.chapters ?? [] }
    var pdfs: [PDFFile] { details?.pdfs.isEmpty == false ? details?.pdfs ?? [] : state.value?.pdfs ?? [] }

    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func refresh() async {
        HearthData.shared.items.invalidate(id)
        await load()
    }

    func load() async {
        do {
            guard case .audiobook(let book) = try await HearthData.shared.items.item(id) else {
                throw APIError.notFound
            }
            state = .loaded(book)
            async let details: Void = loadDetails()
            async let related: Void = loadRelated(book)
            _ = await (details, related)
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }

    private func loadDetails() async {
        if let details = try? await HearthData.shared.items.playableDetails(id) {
            self.details = details
            if case .audiobook(let book) = details.item {
                state = .loaded(book)
            }
        }
    }

    private func loadRelated(_ book: Audiobook) async {
        let items = HearthData.shared.items
        var shelves = [Shelf]()
        for fragment in book.series {
            guard let seriesID = fragment.id else { continue }
            let identifier = ItemIdentifier(kind: .series, connectionID: id.connectionID, libraryID: id.libraryID, primaryID: seriesID)
            if case .series(let series)? = try? await items.item(identifier) {
                let others = series.audiobooks.filter { $0.id != book.id }
                if !others.isEmpty {
                    shelves.append(Shelf(title: String(localized: "More in \(series.name)", table: "Detail"), destination: .item(identifier), books: others))
                }
            }
        }
        seriesShelves = shelves

        guard let client = try? Client.for(id.connectionID) else { return }
        if let author = book.authors.first {
            let results = await items.search(author, scope: .library(id.library))
            if let match = results.authors.first(where: { $0.name.localizedCaseInsensitiveCompare(author) == .orderedSame }),
               let result = try? await client.author(match.id) {
                let others = result.audiobooks.filter { $0.id != book.id }.sorted { ($0.released ?? "") < ($1.released ?? "") }
                if !others.isEmpty {
                    authorShelf = Shelf(title: String(localized: "More by \(author)", table: "Detail"), destination: .item(match.id), books: others)
                }
            }
        }
        if let narrator = book.narrators.first {
            let narratorID = ItemIdentifier(kind: .narrator, connectionID: id.connectionID, libraryID: id.libraryID, primaryID: narrator)
            if let result = try? await client.narrator(narratorID) {
                let others = result.audiobooks.filter { $0.id != book.id }
                if !others.isEmpty {
                    narratorShelf = Shelf(title: String(localized: "Read by \(narrator)", table: "Detail"), destination: .narrator(name: narrator, library: id.library), books: others)
                }
            }
        }
    }
}

private struct AudiobookDetailContent: View {
    let book: Audiobook
    let model: AudiobookDetailModel

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    @State private var dominantColor: HearthRGBColor?
    @State private var isConfiguring = false
    @State private var showsBookmarks = true
    @State private var showsChapters = false
    @State private var showsDocuments = true
    @State private var showsDetails = false

    var body: some View {
        List {
            AudiobookHeader(book: book, tint: dominantColor, compact: sizeClass == .compact)
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))

            if book.descriptionHTML?.isEmpty == false {
                DescriptionView(html: book.descriptionHTML, collapsedLines: 6, seekItemID: book.id)
                    .detailPlainRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
            }

            BookmarksSection(itemID: book.id, isExpanded: $showsBookmarks)

            if model.chapters.count > 1 {
                ChaptersSection(itemID: book.id, chapters: model.chapters, isExpanded: $showsChapters)
            }

            TimelineSection(id: book.id, released: ReleaseDate.date(from: book.released), added: book.addedAt)

            if !model.pdfs.isEmpty {
                DocumentsSection(itemID: book.id, pdfs: model.pdfs, isExpanded: $showsDocuments)
            }

            AudiobookInfoSection(book: book, isExpanded: $showsDetails)

            ForEach(model.seriesShelves) { shelf in
                AudiobookShelf(title: shelf.title, destination: shelf.destination, audiobooks: shelf.books)
                    .detailPlainRow()
            }
            if let shelf = model.authorShelf {
                AudiobookShelf(title: shelf.title, destination: shelf.destination, audiobooks: shelf.books)
                    .detailPlainRow()
            }
            if let shelf = model.narratorShelf {
                AudiobookShelf(title: shelf.title, destination: shelf.destination, audiobooks: shelf.books)
                    .detailPlainRow()
            }
        }
        .listStyle(.plain)
        .heroBackground(color: dominantColor, height: sizeClass == .compact ? 760 : 600)
        .detailNavigationTitle(book.name, threshold: sizeClass == .compact ? 420 : 300)
        .refreshable { await model.refresh() }
        .task(id: book.id) {
            let color = await HearthData.shared.images.dominantColor(for: book.id)
            withAnimation(.smooth) { dominantColor = color }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.pdfs.isEmpty {
                    PDFReadButton(itemID: book.id, pdfs: model.pdfs)
                }
                if book.hasAudio {
                    DownloadToolbarButton(id: book.id)
                }
                PlayableMoreMenu(item: .audiobook(book)) {
                    isConfiguring = true
                }
            }
        }
        .sheet(isPresented: $isConfiguring) {
            ConfigureSheet(id: book.id, title: book.name)
        }
        #if DEBUG
        .onAppear {
            if DebugSupport.expandsSections {
                showsChapters = true
                showsDetails = true
            }
        }
        #endif
    }
}

// MARK: - Header

private struct AudiobookHeader: View {
    let book: Audiobook
    let tint: HearthRGBColor?
    let compact: Bool

    @Environment(\.itemActionHandler) private var handler

    var body: some View {
        if compact {
            VStack(spacing: 14) {
                cover
                    .frame(maxWidth: 270)
                    .padding(.top, 8)
                info(alignment: .center)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .center, spacing: 32) {
                cover
                    .frame(maxWidth: 400)
                    .frame(minWidth: 220)
                info(alignment: .leading)
                    .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private var cover: some View {
        ItemImage(id: book.id, size: .large, cornerRadius: 14)
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            .accessibilityHidden(true)
    }

    private func info(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 8) {
            seriesLinks
            Text(book.name)
                .font(.system(.title, design: .serif, weight: .bold))
                .multilineTextAlignment(textAlignment)
                .lineLimit(4)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = book.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
            }
            authorLinks
            infoLine
                .multilineTextAlignment(textAlignment)
            if book.hasAudio {
                PlayButton(item: .audiobook(book), style: .large, tint: tint)
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
                    .contextMenu {
                        ItemContextMenu(item: .audiobook(book))
                    }
            }
        }
    }

    @ViewBuilder
    private var seriesLinks: some View {
        let series = NavigationDestination.series(of: book)
        if series.count == 1, let entry = series.first {
            DetailLink(value: entry.destination) {
                seriesLabel(entry.title)
            }
            .buttonStyle(.plain)
        } else if series.count > 1 {
            Menu {
                ForEach(series, id: \.title) { entry in
                    Button(entry.title) { handler.navigate(entry.destination) }
                }
            } label: {
                seriesLabel(series.map(\.title).joined(separator: ", "))
            }
            .buttonStyle(.plain)
        }
    }

    private func seriesLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "books.vertical")
            Text(text)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var authorLinks: some View {
        if !book.authors.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(book.authors.prefix(3).enumerated()), id: \.offset) { index, author in
                    if index > 0 {
                        Text(verbatim: "·").foregroundStyle(.secondary)
                    }
                    DetailLink(value: .author(name: author, library: book.id.library)) {
                        Text(author)
                            .font(.headline)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var infoLine: some View {
        HStack(spacing: 6) {
            if book.explicit {
                Image(systemName: "e.square")
                    .accessibilityLabel(String(localized: "Explicit", table: "Detail"))
            }
            if book.abridged {
                Image(systemName: "a.square")
                    .accessibilityLabel(String(localized: "Abridged", table: "Detail"))
            }
            Text(infoText)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var infoText: String {
        let narrators = book.narrators.isEmpty ? nil : String(localized: "Read by \(book.narrators.formatted(.list(type: .and, width: .short)))", table: "Detail")
        return HearthFormat.joined([narrators, HearthFormat.year(from: book.released), HearthFormat.duration(book.duration)])
    }
}

// MARK: - Bookmarks

struct BookmarksSection: View {
    let itemID: ItemIdentifier
    @Binding var isExpanded: Bool

    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation
    @State private var editing: Bookmark?
    @State private var note = ""

    var body: some View {
        let bookmarks = HearthData.shared.bookmarks.bookmarks(for: itemID)
        if !bookmarks.isEmpty {
            Section {
                Group {
                    CollapsibleHeader(title: String(localized: "Bookmarks", table: "Detail"), detail: bookmarks.count.formatted(), isExpanded: $isExpanded)
                }
                .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                if isExpanded {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            Task { await DetailPlayback.play(itemID, at: TimeInterval(bookmark.time), alerts: alerts, presentation: presentation) }
                        } label: {
                            BookmarkRow(bookmark: bookmark)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(bookmark)
                            } label: {
                                Label(String(localized: "Delete", table: "Detail"), systemImage: "trash")
                            }
                            Button {
                                beginEditing(bookmark)
                            } label: {
                                Label(String(localized: "Edit Note", table: "Detail"), systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                beginEditing(bookmark)
                            } label: {
                                Label(String(localized: "Edit Note", table: "Detail"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                delete(bookmark)
                            } label: {
                                Label(String(localized: "Delete", table: "Detail"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .alert(String(localized: "Edit Note", table: "Detail"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField(String(localized: "Note", table: "Detail"), text: $note)
                Button(String(localized: "Save", table: "Detail")) {
                    guard let bookmark = editing else { return }
                    let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        do {
                            try await HearthData.shared.bookmarks.update(bookmark, note: text)
                            alerts.succeed()
                        } catch {
                            alerts.fail(error)
                        }
                    }
                }
                Button(String(localized: "Cancel", table: "Detail"), role: .cancel) {}
            }
        }
    }

    private func beginEditing(_ bookmark: Bookmark) {
        note = bookmark.note
        editing = bookmark
    }

    private func delete(_ bookmark: Bookmark) {
        Task {
            do {
                try await HearthData.shared.bookmarks.delete(bookmark)
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.note)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(bookmark.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(HearthFormat.clock(TimeInterval(bookmark.time)))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Plays from this bookmark", table: "Detail"))
    }
}

// MARK: - Chapters

struct ChaptersSection: View {
    let itemID: ItemIdentifier
    let chapters: [Chapter]
    @Binding var isExpanded: Bool

    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    var body: some View {
        Section {
            Group {
                CollapsibleHeader(title: String(localized: "Chapters", table: "Detail"), detail: chapters.count.formatted(), isExpanded: $isExpanded)
            }
            .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if isExpanded {
                let position = currentPosition
                ForEach(chapters) { chapter in
                    let isCurrent = chapter.contains(position) && position > 0
                    let isPast = chapter.end <= position
                    Button {
                        Task { await DetailPlayback.play(itemID, at: chapter.start, alerts: alerts, presentation: presentation) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(chapter.title)
                                .font(.subheadline.weight(isCurrent ? .bold : .regular))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(HearthFormat.clock(chapter.start))
                                Text(HearthFormat.duration(chapter.duration))
                                    .font(.caption2)
                            }
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(isPast ? .secondary : .primary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                    .accessibilityValue(isCurrent ? String(localized: "Current chapter", table: "Detail") : (isPast ? String(localized: "Played", table: "Detail") : ""))
                    .accessibilityHint(String(localized: "Plays from this chapter", table: "Detail"))
                }
            }
        }
    }

    /// Playback position: live while the item is playing, else the stored progress.
    private var currentPosition: TimeInterval {
        let player = AudioPlayer.shared
        if player.isCurrent(itemID) {
            return player.currentTime
        }
        guard let progress = HearthData.shared.progress.progress(for: itemID), !progress.isFinished else { return 0 }
        return progress.currentTime
    }
}

// MARK: - Documents

private struct DocumentsSection: View {
    let itemID: ItemIdentifier
    let pdfs: [PDFFile]
    @Binding var isExpanded: Bool

    @State private var presented: PDFFile?

    var body: some View {
        Section {
            Group {
                CollapsibleHeader(title: String(localized: "Documents", table: "Detail"), detail: pdfs.count.formatted(), isExpanded: $isExpanded)
            }
            .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if isExpanded {
                ForEach(pdfs) { pdf in
                    Button {
                        presented = pdf
                    } label: {
                        Label {
                            Text(pdf.name)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.tint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fullScreenCover(item: $presented) { pdf in
            PDFReaderView(itemID: itemID, pdf: pdf)
        }
    }
}

// MARK: - Details

private struct AudiobookInfoSection: View {
    let book: Audiobook
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            Group {
                CollapsibleHeader(title: String(localized: "Details", table: "Detail"), isExpanded: $isExpanded)
            }
            .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if isExpanded {
                if let publisher = book.publisher, !publisher.isEmpty {
                    DetailInfoRow(label: String(localized: "Publisher", table: "Detail"), value: publisher)
                }
                if let released = book.released, !released.isEmpty {
                    DetailInfoRow(label: String(localized: "Published", table: "Detail"), value: released)
                }
                if let language = book.language, !language.isEmpty {
                    DetailInfoRow(label: String(localized: "Language", table: "Detail"), value: Locale.current.localizedString(forLanguageCode: language) ?? language)
                }
                if let isbn = book.isbn, !isbn.isEmpty {
                    DetailInfoRow(label: String(localized: "ISBN", table: "Detail"), value: isbn)
                }
                if let asin = book.asin, !asin.isEmpty {
                    DetailInfoRow(label: String(localized: "ASIN", table: "Detail"), value: asin)
                }
                if !book.genres.isEmpty {
                    TagLinksRow(label: String(localized: "Genres", table: "Detail"), values: book.genres) { .filteredAudiobooks(.genre($0), title: $0, library: book.id.library) }
                }
                if !book.tags.isEmpty {
                    TagLinksRow(label: String(localized: "Tags", table: "Detail"), values: book.tags) { .filteredAudiobooks(.tag($0), title: $0, library: book.id.library) }
                }
                if book.duration > 0 {
                    DetailInfoRow(label: String(localized: "Duration", table: "Detail"), value: HearthFormat.duration(book.duration))
                }
                if let added = book.addedAt {
                    DetailInfoRow(label: String(localized: "Added", table: "Detail"), value: added.formatted(date: .long, time: .omitted))
                }
                if let size = book.size, size > 0 {
                    DetailInfoRow(label: String(localized: "Size", table: "Detail"), value: HearthFormat.bytes(size))
                }
            }
        }
    }
}

/// Wrapping capsules linking to filtered lists (genres, tags).
struct TagLinksRow: View {
    let label: String
    let values: [String]
    let destination: (String) -> NavigationDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        DetailLink(value: destination(value)) {
                            Text(value)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.tint.opacity(0.14), in: .capsule)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
