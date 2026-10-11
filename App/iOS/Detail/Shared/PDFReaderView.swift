import HearthData
import HearthModel
import HearthUI
import PDFKit
import SwiftUI

/// Full-screen PDF reader (book display mode). Uses the downloaded file when available, otherwise fetches the
/// PDF from the server.
struct PDFReaderView: View {
    let itemID: ItemIdentifier
    let pdf: PDFFile

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<URL> = .loading

    var body: some View {
        NavigationStack {
            LoadStateView(state, retry: load) { url in
                PDFKitView(url: url)
                    .ignoresSafeArea(edges: .bottom)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: url) {
                                Label(String(localized: "Share", table: "Detail"), systemImage: "square.and.arrow.up")
                            }
                        }
                    }
            }
            .navigationTitle(pdf.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done", table: "Detail")) {
                        dismiss()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let local = HearthData.shared.downloads.localPDFURL(for: itemID, ino: pdf.ino), FileManager.default.fileExists(atPath: local.path()) {
            state = .loaded(local)
            return
        }
        do {
            let client = try Client.for(itemID.connectionID)
            let request = try await client.pdfRequest(for: itemID, ino: pdf.ino)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let name = pdf.name.lowercased().hasSuffix(".pdf") ? pdf.name : pdf.name + ".pdf"
            let directory = FileManager.default.temporaryDirectory.appending(path: "PDFs/\(itemID.fileSafe)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: url, options: .atomic)
            state = .loaded(url)
        } catch {
            state = .failed(error)
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysAsBook = true
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
