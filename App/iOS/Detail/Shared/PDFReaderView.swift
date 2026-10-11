import HearthAPI
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
            let data = try await PDFFetcher.fetch(itemID, ino: pdf.ino)
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

/// Fetches a PDF with the connection's TLS rules (pinned self-signed certificate, client certificate) and a
/// fresh access token – like the API client, not through `URLSession.shared`.
@MainActor
private enum PDFFetcher {
    static func fetch(_ itemID: ItemIdentifier, ino: String) async throws -> Data {
        let client = try Client.for(itemID.connectionID)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let delegate = PDFTrustDelegate(connection: client.connection)

        var (data, status) = try await load(client: client, itemID: itemID, ino: ino, session: session, delegate: delegate)
        if status == 401 {
            // The access token expired: any API call refreshes it, then the file request is rebuilt.
            _ = try await client.me()
            (data, status) = try await load(client: client, itemID: itemID, ino: ino, session: session, delegate: delegate)
        }
        guard (200..<300).contains(status) else {
            throw status == 401 ? APIError.unauthorized : APIError.invalidResponse(statusCode: status)
        }
        return data
    }

    private static func load(client: any AudiobookshelfClient, itemID: ItemIdentifier, ino: String, session: URLSession, delegate: PDFTrustDelegate) async throws -> (Data, Int) {
        let request = try await client.pdfRequest(for: itemID, ino: ino)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Server trust with the connection's pinned certificate; client certificate (mTLS) when configured.
private final class PDFTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let pinnedSHA256: String?
    let connectionID: ConnectionID

    init(connection: Connection) {
        pinnedSHA256 = connection.pinnedCertificateSHA256
        connectionID = connection.id
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return ServerTrust.handle(challenge, pinnedSHA256: pinnedSHA256)
        case NSURLAuthenticationMethodClientCertificate:
            if let identity = APIClientFactory.clientIdentityProvider?(connectionID) {
                return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
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
