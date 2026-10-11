import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Synchronization
import Testing

@Suite("DownloadManager")
@MainActor
struct DownloadManagerTests {
    struct Setup {
        let hearth: HearthData
        let book: ItemIdentifier
        let audio: DownloadAsset
        let cover: DownloadAsset
    }

    /// A download in progress (audio task 7, cover task 8) loaded from the database at launch. The connection is
    /// unauthorized so no network tasks are created; session callbacks are fed in with `handle(_:)`.
    func makeDownloading() async -> Setup {
        let client = MockClient(connection: Fixtures.connection())
        let previousRun = makeHearth([client])
        let book = Fixtures.book("b1", connection: client.connection.id)
        let audio = DownloadAsset(itemID: book.id, kind: .audio, relativePath: DownloadPaths.audio(book.id, index: 0, fileExtension: "m4b"), ino: "1", taskIdentifier: 7, weight: 80)
        let cover = DownloadAsset(itemID: book.id, kind: .cover, relativePath: DownloadPaths.cover(book.id, size: .large), imageSize: .large, taskIdentifier: 8, weight: 10)
        await previousRun.environment.store.perform { context in
            context.saveItem(.audiobook(book), downloaded: false)
            context.upsertAssets([audio, cover])
        }
        let hearth = HearthData(environment: previousRun.environment, settings: previousRun.settings)
        hearth.connections.markUnauthorized(client.connection.id)
        return Setup(hearth: hearth, book: book.id, audio: audio, cover: cover)
    }

    func failure(_ asset: DownloadAsset, _ error: any Error, task: Int? = nil) -> DownloadEvent {
        .finished(assetID: asset.id, taskIdentifier: task ?? asset.taskIdentifier ?? 0, result: .failure(error), resumeData: nil)
    }

    func failureCount(_ setup: Setup, _ asset: DownloadAsset) async -> Int? {
        await setup.hearth.environment.store.perform { $0.assets().first { $0.id == asset.id }?.failureCount }
    }

    @Test func classifiesFailures() {
        #expect(DownloadManager.classify(URLError(.cancelled)) == .cancelled)
        #expect(DownloadManager.classify(DownloadTaskError.discarded) == .cancelled)
        #expect(DownloadManager.classify(DownloadTaskError.unauthorized(nil)) == .unauthorized)
        #expect(DownloadManager.classify(DownloadTaskError.httpStatus(404)) == .permanent)
        #expect(DownloadManager.classify(DownloadTaskError.httpStatus(403)) == .permanent)
        #expect(DownloadManager.classify(DownloadTaskError.httpStatus(503)) == .transient)
        #expect(DownloadManager.classify(URLError(.networkConnectionLost)) == .transient)
    }

    @Test func cancellationsAndUnauthorizedDontCountAsFailures() async {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        #expect(downloads.status(of: setup.book) == .downloading)

        // Force quits cancel background tasks; resuming after more than `maxRetries` of them keeps the download.
        for _ in 0 ... DownloadManager.maxRetries + 1 {
            await downloads.handle(failure(setup.audio, URLError(.cancelled)))
            await downloads.handle(failure(setup.audio, DownloadTaskError.unauthorized(nil)))
        }
        #expect(downloads.status(of: setup.book) == .downloading)
        #expect(await failureCount(setup, setup.audio) == 0)
    }

    @Test func transientFailuresAreCountedThenGivenUp() async {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        for attempt in 1 ... DownloadManager.maxRetries {
            await downloads.handle(failure(setup.audio, DownloadTaskError.httpStatus(503), task: attempt == 1 ? 7 : 0))
            #expect(await failureCount(setup, setup.audio) == attempt)
        }
        #expect(downloads.status(of: setup.book) == .downloading)
        await downloads.handle(failure(setup.audio, URLError(.timedOut), task: 0))
        #expect(downloads.status(of: setup.book) == .none)
    }

    @Test func dataFlowingAgainResetsFailures() async {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        await downloads.handle(failure(setup.audio, DownloadTaskError.httpStatus(503)))
        #expect(await failureCount(setup, setup.audio) == 1)
        await downloads.handle(.progress(assetID: setup.audio.id, written: 10, expected: 100))
        #expect(await failureCount(setup, setup.audio) == 0)
    }

    @Test func permanentFailuresGiveUpImmediately() async {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        // Optional assets are dropped, the download continues.
        await downloads.handle(failure(setup.cover, DownloadTaskError.httpStatus(404)))
        #expect(downloads.status(of: setup.book) == .downloading)
        #expect(await setup.hearth.environment.store.perform { $0.assets().map(\.id) } == [setup.audio.id])

        await downloads.handle(failure(setup.audio, DownloadTaskError.httpStatus(403)))
        #expect(downloads.status(of: setup.book) == .none)
    }

    @Test func completionOfReplacedTaskIsIgnored() async {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        // Task 3 was replaced by task 7 (e.g. restarted after a force quit before its cancellation arrived).
        await downloads.handle(failure(setup.audio, DownloadTaskError.httpStatus(404), task: 3))
        #expect(downloads.status(of: setup.book) == .downloading)
    }

    @Test func callsEveryBackgroundCompletionHandlerAfterEvents() async throws {
        let setup = await makeDownloading()
        let downloads = setup.hearth.downloads
        let calls = Mutex(0)

        // watchOS may hand over several handlers.
        downloads.handleBackgroundEvents(identifier: DownloadManager.sessionIdentifier) { calls.withLock { $0 += 1 } }
        downloads.handleBackgroundEvents(identifier: DownloadManager.sessionIdentifier) { calls.withLock { $0 += 1 } }
        await downloads.handle(failure(setup.audio, URLError(.cancelled)))
        #expect(calls.withLock { $0 } == 0)
        await downloads.handle(.allEventsDelivered)
        #expect(calls.withLock { $0 } == 2)

        // Events delivered before the handler arrives: called once the queued work is done.
        await downloads.handle(.allEventsDelivered)
        downloads.handleBackgroundEvents(identifier: DownloadManager.sessionIdentifier) { calls.withLock { $0 += 1 } }
        for _ in 0 ..< 200 where calls.withLock({ $0 }) < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(calls.withLock { $0 } == 3)
    }

    @Test func finishedFilesOfRemovedAssetsAreDiscarded() throws {
        let environment = DataEnvironment.ephemeral(clientFactory: { connection, _, _ in MockClient(connection: connection) })
        let active = ActiveDownloadAssets()
        let delegate = DownloadSessionDelegate(root: environment.downloadsURL, trust: environment.trust, active: active, send: { _ in })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        func finish(_ assetID: String, path: String) throws {
            let task = session.downloadTask(with: Fixtures.host)
            task.taskDescription = DownloadTaskDescription(assetID: assetID, relativePath: path).encoded
            let location = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("audio".utf8).write(to: location)
            delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: location)
        }

        try finish("removed", path: "conn/lib/removed/audio-0.m4b")
        #expect(!FileManager.default.fileExists(atPath: environment.downloadsURL.appending(path: "conn/lib/removed").path))

        active.insert(["kept"])
        try finish("kept", path: "conn/lib/kept/audio-0.m4b")
        #expect(FileManager.default.fileExists(atPath: environment.downloadsURL.appending(path: "conn/lib/kept/audio-0.m4b").path))
    }
}
