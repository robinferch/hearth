import Foundation
import HearthModel
import Testing
@testable import HearthAPI

@Suite struct URLBuildingTests {
    @Test(arguments: [
        ("https://abs.example.com", "https://abs.example.com/api/libraries"),
        ("https://abs.example.com/", "https://abs.example.com/api/libraries"),
        ("https://example.com/abs", "https://example.com/abs/api/libraries"),
        ("https://example.com/abs/", "https://example.com/abs/api/libraries"),
        ("http://192.168.1.2:13378/sub/path", "http://192.168.1.2:13378/sub/path/api/libraries"),
    ])
    func appendsPathToHost(host: String, expected: String) throws {
        let url = try URLBuilder.url(host: URL(string: host)!, path: ["api", "libraries"])
        #expect(url.absoluteString == expected)
    }

    @Test func encodesEachComponentSeparately() throws {
        let url = try URLBuilder.url(host: URL(string: "https://example.com/abs")!, path: ["api", "items", "a/b c+d=", "file"])
        #expect(url.absoluteString == "https://example.com/abs/api/items/a%2Fb%20c%2Bd%3D/file")
    }

    @Test func encodesQueryValuesStrictly() throws {
        let url = try URLBuilder.url(host: URL(string: "https://example.com")!, path: ["api", "x"], query: [
            URLQueryItem(name: "filter", value: "genres.U2NpLUZp+/=="),
            URLQueryItem(name: "q", value: "a&b c"),
        ])
        #expect(url.absoluteString == "https://example.com/api/x?filter=genres.U2NpLUZp%2B%2F%3D%3D&q=a%26b%20c")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "genres.U2NpLUZp+/==")
    }

    @Test func socketURLUsesWebSocketSchemeAndSubPath() throws {
        let secure = try URLBuilder.socketURL(host: URL(string: "https://example.com/abs")!)
        #expect(secure.absoluteString == "wss://example.com/abs/socket.io/?EIO=4&transport=websocket")
        let plain = try URLBuilder.socketURL(host: URL(string: "http://10.0.0.2:13378")!)
        #expect(plain.absoluteString == "ws://10.0.0.2:13378/socket.io/?EIO=4&transport=websocket")
    }

    @Test(arguments: [
        ("https://example.com", "/api/items/li/file/1", "https://example.com/api/items/li/file/1"),
        ("https://example.com/abs", "/api/items/li/file/1", "https://example.com/abs/api/items/li/file/1"),
        ("https://example.com/abs/", "/abs/api/items/li/file/1", "https://example.com/abs/api/items/li/file/1"),
        ("https://example.com/abs", "api/items/li/file/1?token=x", "https://example.com/abs/api/items/li/file/1?token=x"),
        ("https://example.com/abs", "https://cdn.example.com/a.mp3", "https://cdn.example.com/a.mp3"),
    ])
    func resolvesServerPaths(host: String, path: String, expected: String) {
        #expect(URLBuilder.resolve(serverPath: path, host: URL(string: host)!)?.absoluteString == expected)
    }

    @Test func rejectsHostWithoutHostname() {
        #expect(throws: APIError.invalidURL) {
            try URLBuilder.url(host: URL(string: "file:///tmp")!, path: ["api"])
        }
    }

    @Test func requestHeadersAreSortedThenBearerThenPerRequest() throws {
        var request = try APIRequest.post("api", "x").json(["a": 1])
        request.headers["X-Extra"] = "1"
        let headers = [HTTPHeader(key: "Z-Proxy", value: "z"), HTTPHeader(key: "A-Proxy", value: "a"), HTTPHeader(key: "Authorization", value: "Basic proxy")]
        let urlRequest = try request.urlRequest(host: URL(string: "https://example.com/abs")!, connectionHeaders: headers, accessToken: "tok")
        #expect(urlRequest.url?.absoluteString == "https://example.com/abs/api/x")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "A-Proxy") == "a")
        #expect(urlRequest.value(forHTTPHeaderField: "Z-Proxy") == "z")
        // The bearer token is applied after custom headers and therefore wins.
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Extra") == "1")
        #expect(urlRequest.timeoutInterval == 45)
    }
}

@Suite struct FilterQueryTests {
    private func filterValue(_ filter: LibraryItemFilter?) throws -> String? {
        let request = APIClient.itemsRequest(library: "lib", sort: nil, direction: .descending, filter: filter, collapseSeries: true, page: 2, limit: 50)
        let url = try URLBuilder.url(host: URL(string: "https://example.com")!, path: request.path, query: request.query)
        return url.query(percentEncoded: true)
    }

    @Test func encodesProgressFilter() throws {
        let query = try #require(try filterValue(.progress(.inProgress)))
        #expect(query == "limit=50&page=2&desc=1&collapseseries=1&filter=progress.aW4tcHJvZ3Jlc3M%3D")
    }

    @Test func omitsAllProgressFilter() throws {
        #expect(try filterValue(.progress(.all)) == "limit=50&page=2&desc=1&collapseseries=1")
    }

    @Test func base64SpecialCharactersArePercentEncoded() throws {
        // "Sci-Fi?>" encodes to base64 containing "+" and "/" which must not be sent raw.
        let genre = "Sci-Fi?>>"
        let base64 = Data(genre.utf8).base64EncodedString()
        #expect(base64.contains("/") || base64.contains("+"))
        let query = try #require(try filterValue(.genre(genre)))
        let encoded = try #require(query.components(separatedBy: "filter=").last)
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(encoded.removingPercentEncoding == "genres." + base64)
    }

    @Test func seriesAndNarratorFilters() throws {
        #expect(LibraryItemFilter.series(id: "ser_1").queryValue == "series." + Data("ser_1".utf8).base64EncodedString())
        #expect(LibraryItemFilter.narrator(name: "Kate Reading").queryValue == "narrators.S2F0ZSBSZWFkaW5n")
    }

    @Test func sortParameterIsOptional() throws {
        let sorted = APIClient.itemsRequest(library: "lib", sort: AudiobookSortOrder.title.rawValue, direction: .ascending, filter: nil, collapseSeries: false, page: 0, limit: 10)
        #expect(sorted.query.contains(URLQueryItem(name: "sort", value: "media.metadata.title")))
        #expect(sorted.query.contains(URLQueryItem(name: "desc", value: "0")))
        let unsorted = APIClient.itemsRequest(library: "lib", sort: nil, direction: .ascending, filter: nil, collapseSeries: false, page: 0, limit: 10)
        #expect(!unsorted.query.contains { $0.name == "sort" })
    }
}
