import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Download button with progress ring (tap cancels) / downloaded state (tap offers removal).
struct DownloadToolbarButton: View {
    let id: ItemIdentifier

    @Environment(\.itemActionHandler) private var handler
    @State private var confirmsRemoval = false

    var body: some View {
        let status = ItemStatus.of(id)
        Button {
            if status.isDownloading {
                Task { await handler.cancelDownload(id) }
            } else if status.isDownloaded {
                confirmsRemoval = true
            } else {
                Task { await handler.download(id) }
            }
        } label: {
            if status.isDownloading {
                DownloadProgressRing(progress: status.downloadProgress, lineWidth: 2.5)
                    .frame(width: 22, height: 22)
            } else if status.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .accessibilityLabel(accessibilityLabel(status))
        .accessibilityValue(status.isDownloading ? HearthFormat.percent(status.downloadProgress) : "")
        .sensoryFeedback(.success, trigger: status.isDownloaded) { _, new in new }
        .confirmationDialog(String(localized: "Remove Download", table: "Detail"), isPresented: $confirmsRemoval, titleVisibility: .hidden) {
            Button(String(localized: "Remove Download", table: "Detail"), role: .destructive) {
                Task { await handler.removeDownload(id) }
            }
        }
    }

    private func accessibilityLabel(_ status: ItemStatus) -> String {
        if status.isDownloading { return String(localized: "Cancel Download", table: "Detail") }
        if status.isDownloaded { return String(localized: "Downloaded", table: "Detail") }
        return String(localized: "Download", table: "Detail")
    }
}

/// "Read" button for PDFs attached to an audiobook (menu when there are several).
struct PDFReadButton: View {
    let itemID: ItemIdentifier
    let pdfs: [PDFFile]

    @State private var presented: PDFFile?

    var body: some View {
        Group {
            if pdfs.count == 1, let pdf = pdfs.first {
                Button {
                    presented = pdf
                } label: {
                    Label(String(localized: "Read", table: "Detail"), systemImage: "book.pages")
                }
            } else if pdfs.count > 1 {
                Menu {
                    ForEach(pdfs) { pdf in
                        Button(pdf.name) { presented = pdf }
                    }
                } label: {
                    Label(String(localized: "Read", table: "Detail"), systemImage: "book.pages")
                }
            }
        }
        .fullScreenCover(item: $presented) { pdf in
            PDFReaderView(itemID: itemID, pdf: pdf)
        }
    }
}

/// Ellipsis menu of a playable item: the shared item menu plus "Configure".
struct PlayableMoreMenu: View {
    let item: AnyPlayableItem
    var context: ItemActionContext = .standard
    var configure: (() -> Void)?

    var body: some View {
        Menu {
            ItemContextMenu(item: item, context: context)
            if let configure {
                Section {
                    Button(action: configure) {
                        Label(String(localized: "Configure", table: "Detail"), systemImage: "slider.horizontal.3")
                    }
                }
            }
        } label: {
            Label(String(localized: "More", table: "Detail"), systemImage: "ellipsis")
        }
    }
}
