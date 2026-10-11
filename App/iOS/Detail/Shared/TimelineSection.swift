import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Listening history of an item: total listening time, last played, sessions, plus "released" / "added" markers.
struct TimelineSection: View {
    let id: ItemIdentifier
    let released: Date?
    let added: Date?

    @State private var isExpanded = false
    @State private var sessions: LoadState<[ListeningSession]> = .loading
    @State private var showsAll = false

    var body: some View {
        Section {
            Group {
                CollapsibleHeader(title: String(localized: "Timeline", table: "Detail"), isExpanded: $isExpanded)
            }
            .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if isExpanded {
                content
            }
        }
        .listRowBackground(Color.clear)
        #if DEBUG
        .onAppear {
            if DebugSupport.expandsSections {
                isExpanded = true
            }
        }
        #endif
        .task(id: isExpanded) {
            guard isExpanded, sessions.value == nil else { return }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sessions {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
        case .failed(let error):
            Text(error.userMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .loaded(let sessions):
            summary(sessions)
            let shown = showsAll ? sessions : Array(sessions.prefix(8))
            ForEach(entries(shown, all: sessions), id: \.id) { entry in
                switch entry {
                case .session(let session):
                    SessionRow(session: session)
                case .marker(let title, let date, let symbol):
                    MarkerRow(title: title, date: date, systemImage: symbol)
                }
            }
            if sessions.count > shown.count {
                Button(String(localized: "Show All Sessions", table: "Detail")) {
                    withAnimation { showsAll = true }
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func summary(_ sessions: [ListeningSession]) -> some View {
        let total = sessions.reduce(0) { $0 + $1.timeListening }
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(String(localized: "Total Listening Time", table: "Detail"), value: total > 0 ? HearthFormat.totalTime(total) : "–")
            if let last = sessions.map(\.updatedAt).max() {
                LabeledContent(String(localized: "Last Played", table: "Detail"), value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if sessions.isEmpty {
                Text("No listening sessions yet.", tableName: "Detail")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private enum Entry {
        case session(ListeningSession)
        case marker(title: String, date: Date, systemImage: String)

        var id: String {
            switch self {
            case .session(let session): session.id
            case .marker(let title, _, _): "marker-\(title)"
            }
        }

        var date: Date {
            switch self {
            case .session(let session): session.updatedAt
            case .marker(_, let date, _): date
            }
        }
    }

    private func entries(_ shown: [ListeningSession], all: [ListeningSession]) -> [Entry] {
        var entries = shown.map(Entry.session)
        let oldestShown = shown.map(\.startedAt).min() ?? .distantFuture
        let complete = shown.count == all.count
        if let added, complete || added >= oldestShown {
            entries.append(.marker(title: String(localized: "Added to library", table: "Detail"), date: added, systemImage: "plus.circle"))
        }
        if let released, complete || released >= oldestShown {
            entries.append(.marker(title: String(localized: "Released", table: "Detail"), date: released, systemImage: "sparkles"))
        }
        return entries.sorted { $0.date > $1.date }
    }

    private func load() async {
        do {
            sessions = .loaded(try await HearthData.shared.listening.listeningSessions(for: id))
        } catch {
            sessions = .failed(error)
        }
    }
}

private struct SessionRow: View {
    let session: ListeningSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "headphones")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(HearthFormat.duration(session.timeListening))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let range = String(localized: "\(HearthFormat.clock(session.startTime)) → \(HearthFormat.clock(session.currentTime))", table: "Detail")
        return HearthFormat.joined([range, session.deviceName])
    }
}

private struct MarkerRow: View {
    let title: String
    let date: Date
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Parses ABS `publishedDate` / `publishedYear` strings ("2021-04-03", "2021").
enum ReleaseDate {
    static func date(from released: String?) -> Date? {
        guard let released, !released.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(released.prefix(format.count))) {
                return date
            }
        }
        return nil
    }
}
