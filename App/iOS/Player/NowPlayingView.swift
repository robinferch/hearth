import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI
import TipKit

/// Full-screen player.
///
/// iPhone: cover (shrinks while paused), title block + bookmark button, chapter scrubber, transport, volume (or
/// total progress) and the action row (speed, sleep timer, AirPlay, queue). The queue toggle swaps the cover for
/// the chapters / queue panel with a 72 pt thumbnail. iPad landscape: two columns with the panel always visible.
struct NowPlayingView: View {
    @Environment(PlayerPresentation.self) private var presentation
    @Environment(\.itemActionHandler) private var handler

    @State private var showsPanel = false
    @State private var panelPage: PlayerPanel.Page = .chapters
    @State private var color: HearthRGBColor?
    @State private var lastPlayed: AnyPlayableItem?
    @State private var errorMessage: String?
    @State private var isBookmarkPromptPresented = false
    @State private var bookmarkNote = ""
    @State private var bookmarkTrigger = 0
    @Namespace private var coverNamespace

    private var player: AudioPlayer { .shared }
    private var item: AnyPlayableItem? { player.currentItem ?? lastPlayed }
    private var itemID: ItemIdentifier? { player.currentItem?.id ?? player.lastPlayedItemID }

    var body: some View {
        GeometryReader { proxy in
            let twoColumns = proxy.size.width > proxy.size.height && proxy.size.width >= 900
            ZStack {
                PlayerBackground(color: color)
                if twoColumns {
                    wideLayout(size: proxy.size)
                } else {
                    portraitLayout(size: proxy.size)
                        .frame(maxWidth: 600)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .overlay(alignment: .top) {
            grabber
        }
        .task(id: itemID) {
            PlayerTips.configureIfNeeded()
            if let itemID {
                if player.currentItem == nil {
                    lastPlayed = try? await HearthData.shared.items.playable(itemID)
                }
                let value = await HearthData.shared.images.dominantColor(for: itemID)
                withAnimation(.smooth) { color = value }
            }
        }
        .onChange(of: player.currentItem == nil && player.lastPlayedItemID == nil) { _, nothing in
            if nothing {
                presentation.collapse()
            }
        }
        .alert(String(localized: "New Bookmark", table: "Player"), isPresented: $isBookmarkPromptPresented) {
            TextField(String(localized: "Note", table: "Player"), text: $bookmarkNote)
            Button(String(localized: "Create", table: "Player")) {
                let note = bookmarkNote
                bookmarkNote = ""
                createBookmark(note: note)
            }
            Button(String(localized: "Cancel", table: "Player"), role: .cancel) {
                bookmarkNote = ""
            }
        } message: {
            Text("Leave the note empty to use the current date and time.", tableName: "Player")
        }
        .alert(String(localized: "Something Went Wrong", table: "Player"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "OK", table: "Player"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: bookmarkTrigger)
        #if DEBUG
        .onAppear {
            if let panel = DebugSupport.initialPlayerPanel {
                showsPanel = true
                panelPage = panel == "queue" ? .queue : .chapters
            }
        }
        #endif
    }

    // MARK: Layouts

    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            if showsPanel {
                compactHeader
                    .padding(.top, 28)
                PlayerPanel(page: $panelPage, onError: show)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Spacer(minLength: 24)
                cover(maxSide: min(size.width - 48, size.height * 0.46, 520))
                Spacer(minLength: 16)
                titleRow
            }
            controls
                .padding(.top, showsPanel ? 8 : 20)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func wideLayout(size: CGSize) -> some View {
        HStack(spacing: 48) {
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                cover(maxSide: min(size.width * 0.38, size.height * 0.5))
                Spacer(minLength: 20)
                titleRow
                controls
                    .padding(.top, 20)
            }
            .frame(maxWidth: 520)
            PlayerPanel(page: $panelPage, onError: show)
                .frame(maxWidth: 480)
                .padding(.top, 40)
        }
        .padding(.horizontal, 48)
        .padding(.bottom, 16)
    }

    private var grabber: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            HStack {
                Spacer()
                Button {
                    presentation.collapse()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .environment(\.colorScheme, .dark)
                .accessibilityLabel(String(localized: "Close Player", table: "Player"))
                .padding(.trailing, 16)
                .padding(.top, 4)
            }
        }
    }

    // MARK: Cover

    private func cover(maxSide: CGFloat) -> some View {
        let playing = player.isPlaying || player.currentItem == nil
        return ItemImage(id: itemID, size: .large, cornerRadius: 18)
            .matchedGeometryEffect(id: "cover", in: coverNamespace)
            .frame(width: max(maxSide, 120), height: max(maxSide, 120))
            .shadow(color: .black.opacity(playing ? 0.45 : 0.25), radius: playing ? 30 : 14, y: playing ? 16 : 8)
            .scaleEffect(playing ? 1 : 0.84)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: playing)
            .accessibilityHidden(true)
    }

    private var compactHeader: some View {
        HStack(spacing: 14) {
            ItemImage(id: itemID, size: .small, cornerRadius: 10)
                .matchedGeometryEffect(id: "cover", in: coverNamespace)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .accessibilityHidden(true)
            titleBlock
            Spacer(minLength: 0)
            bookmarkButton
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            titleBlock
            Spacer(minLength: 0)
            bookmarkButton
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        Menu {
            if let item {
                PlayerItemLinks(item: item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if case .episode(let episode) = item, let date = episode.publishedAt {
                    Text(HearthFormat.releaseDate(date))
                        .font(.caption.smallCaps().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item?.name ?? String(localized: "Not Playing", table: "Player"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Shows links to the item", table: "Player"))
    }

    private var subtitle: String? {
        switch item {
        case .audiobook(let book): book.authorLine
        case .episode(let episode): episode.podcastName
        case nil: nil
        }
    }

    @ViewBuilder
    private var bookmarkButton: some View {
        if player.canCreateBookmark {
            Button {
                isBookmarkPromptPresented = true
            } label: {
                Image(systemName: "bookmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: bookmarkTrigger)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    PlayerTips.bookmarkLongPress.invalidate(reason: .actionPerformed)
                    createBookmark(note: nil)
                }
            )
            .popoverTip(PlayerTips.bookmarkLongPress, arrowEdge: .bottom)
            .accessibilityLabel(String(localized: "Add Bookmark", table: "Player"))
            .accessibilityAction(named: String(localized: "Add Quick Bookmark", table: "Player")) {
                createBookmark(note: nil)
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if player.currentItem != nil {
            VStack(spacing: 14) {
                PlayerScrubberSection()
                TransportControls(compact: showsPanel)
                if AppSettings.shared.replaceVolumeWithTotalProgress {
                    TotalProgressSlider()
                } else {
                    VolumeSlider()
                }
                actionRow
            }
        } else {
            resumeControls
        }
    }

    private var actionRow: some View {
        HStack {
            SpeedButton()
                .frame(maxWidth: .infinity)
            SleepTimerButton()
                .frame(maxWidth: .infinity)
            RoutePickerButton(route: player.route)
                .frame(maxWidth: .infinity)
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    showsPanel.toggle()
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background {
                        if showsPanel {
                            Circle().fill(.white.opacity(0.2))
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(String(localized: "Chapters and Queue", table: "Player"))
            .accessibilityAddTraits(showsPanel ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: showsPanel)
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    private var resumeControls: some View {
        VStack(spacing: 16) {
            Button {
                Task {
                    do {
                        try await player.resumeLastPlayed()
                    } catch {
                        show(error)
                    }
                }
            } label: {
                Label(String(localized: "Resume", table: "Player"), systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            if let id = itemID, let progress = HearthData.shared.progress.progress(for: id), progress.isInProgress {
                Text(HearthFormat.remaining(progress.remaining ?? 0, rate: ItemStatus.effectiveRate(for: id)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
    }

    // MARK: Actions

    private func createBookmark(note: String?) {
        Task {
            do {
                try await player.createBookmark(note: note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? note : nil)
                bookmarkTrigger += 1
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: any Error) {
        errorMessage = error.userMessage
    }
}

/// Links from the player's title menu: item, authors, narrators, series or podcast.
struct PlayerItemLinks: View {
    let item: AnyPlayableItem

    @Environment(\.itemActionHandler) private var handler

    var body: some View {
        switch item {
        case .audiobook(let book):
            Button {
                handler.navigate(.item(book.id))
            } label: {
                Label(String(localized: "Go to Audiobook", table: "Player"), systemImage: "book.closed")
            }
            ForEach(book.authors, id: \.self) { author in
                Button {
                    handler.navigate(.author(name: author, library: book.id.library))
                } label: {
                    Label(author, systemImage: "person")
                }
            }
            ForEach(NavigationDestination.series(of: book), id: \.title) { entry in
                Button {
                    handler.navigate(entry.destination)
                } label: {
                    Label(entry.title, systemImage: "books.vertical")
                }
            }
            ForEach(book.narrators, id: \.self) { narrator in
                Button {
                    handler.navigate(.narrator(name: narrator, library: book.id.library))
                } label: {
                    Label(narrator, systemImage: "waveform")
                }
            }
        case .episode(let episode):
            Button {
                handler.navigate(.item(episode.id))
            } label: {
                Label(String(localized: "Go to Episode", table: "Player"), systemImage: "waveform.circle")
            }
            if let podcast = episode.id.podcastIdentifier {
                Button {
                    handler.navigate(.item(podcast))
                } label: {
                    Label(episode.podcastName, systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
    }
}

/// Dark background tinted with the cover's dominant color.
private struct PlayerBackground: View {
    let color: HearthRGBColor?

    var body: some View {
        let base = color ?? HearthRGBColor(red: 0.25, green: 0.22, blue: 0.2)
        let top = Color(red: base.red * 0.62, green: base.green * 0.62, blue: base.blue * 0.62)
        let bottom = Color(red: base.red * 0.22, green: base.green * 0.22, blue: base.blue * 0.22)
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .overlay(Color.black.opacity(0.08))
            .ignoresSafeArea()
            .animation(.smooth(duration: 0.6), value: color)
    }
}
