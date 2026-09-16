import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Services

final class UploadServiceTests: XCTestCase {
    func testMultipartBodyUsesFilePartAndPreservesBinaryBytes() throws {
        let bytes = Data([0x50, 0x4E, 0x47, 0x00, 0xFF])
        let body = try UploadService.makeMultipartBody(
            filename: "/unsafe/path\"name.png",
            mime: "image/png",
            bytes: bytes,
            boundary: "test-boundary"
        )
        let prefix = Data(
            "--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"path_name.png\"\r\nContent-Type: image/png\r\n\r\n".utf8
        )
        let suffix = Data("\r\n--test-boundary--\r\n".utf8)
        XCTAssertTrue(body.starts(with: prefix))
        XCTAssertEqual(body.suffix(suffix.count), suffix)
        XCTAssertEqual(body.subdata(in: prefix.count..<(body.count - suffix.count)), bytes)
    }

    func testUploadBuildsBearerMultipartRequestAndReturnsAbsolutePath() async throws {
        let client = RecordingUploadClient(
            responseData: Data(#"{"path":"/tmp/uploaded.png"}"#.utf8),
            statusCode: 200
        )
        let service = UploadService(client: client)
        let token = "token-must-not-appear-in-errors"
        let path = try await service.upload(
            url: URL(string: "http://127.0.0.1:9900/upload")!,
            token: token,
            filename: "image.png",
            mime: "image/png",
            bytes: Data([1, 2, 0, 255])
        )

        XCTAssertEqual(path, "/tmp/uploaded.png")
        let requestValue = await client.request
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let bodyValue = await client.body
        let body = try XCTUnwrap(bodyValue)
        XCTAssertTrue(body.range(of: Data("name=\"file\"".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data("Content-Type: image/png".utf8)) != nil)
        XCTAssertTrue(body.range(of: Data([1, 2, 0, 255])) != nil)
        XCTAssertFalse(contentType.contains(token))
    }

    func testUploadMapsUnauthorizedAndNetworkFailuresWithoutTokenText() async throws {
        let unauthorizedClient = RecordingUploadClient(responseData: Data(), statusCode: 401)
        let token = "private-token"
        let unauthorized = UploadService(client: unauthorizedClient)
        await assertUploadThrows(try await unauthorized.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: token,
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains(token))
        }

        let unreachableClient = RecordingUploadClient(failure: .network)
        let unreachable = UploadService(client: unreachableClient)
        await assertUploadThrows(try await unreachable.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: token,
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .unreachable)
            XCTAssertFalse(String(describing: error).contains(token))
        }
    }

    func testUploadMapsTimeoutAndRejectsHeaderInjection() async throws {
        let timedOut = UploadService(client: RecordingUploadClient(failure: .timedOut))
        await assertUploadThrows(try await timedOut.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: "token",
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .timeout)
        }

        let injection = UploadService(client: RecordingUploadClient(responseData: Data(), statusCode: 200))
        await assertUploadThrows(try await injection.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: "token\r\nX-Leak: true",
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .invalidRequest)
        }
    }

    func testUploadRejectsMalformedResponsesAndInvalidRequests() async throws {
        let malformed = UploadService(client: RecordingUploadClient(
            responseData: Data(#"{"path":"relative.png"}"#.utf8),
            statusCode: 200
        ))
        await assertUploadThrows(try await malformed.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: "token",
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .invalidResponse)
        }

        let emptyClient = RecordingUploadClient(responseData: Data(), statusCode: 200)
        let empty = UploadService(client: emptyClient)
        await assertUploadThrows(try await empty.upload(
            url: URL(string: "https://daemon.example/upload")!,
            token: "token",
            filename: "image",
            mime: "image/png",
            bytes: Data()
        )) { error in
            XCTAssertEqual(error as? UploadError, .invalidFile)
        }
        let emptyRequest = await emptyClient.request
        XCTAssertNil(emptyRequest)

        let badURL = UploadService(client: emptyClient)
        await assertUploadThrows(try await badURL.upload(
            url: URL(string: "file:///tmp/upload")!,
            token: "token",
            filename: "image",
            mime: "image/png",
            bytes: Data([1])
        )) { error in
            XCTAssertEqual(error as? UploadError, .invalidURL)
        }
    }
}

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testReadTextUsesPublicPlainTextThenLegacyString() {
        let pasteboard = FakePasteboard()
        pasteboard.strings["public.utf8-plain-text"] = "Unicode ✓"
        let service = ClipboardService(pasteboard: pasteboard)
        XCTAssertEqual(service.readText(), "Unicode ✓")

        pasteboard.strings.removeAll()
        pasteboard.strings[NSPasteboard.PasteboardType.string.rawValue] = "legacy"
        XCTAssertEqual(service.readText(), "legacy")
    }

    func testReadImageReturnsBase64ContractInSupportedOrder() throws {
        let pasteboard = FakePasteboard()
        let jpeg = Data([0xFF, 0xD8, 0x00, 0xD9])
        pasteboard.data[UTType.jpeg.identifier] = jpeg
        let service = ClipboardService(pasteboard: pasteboard)
        let image = try XCTUnwrap(service.readImage())

        XCTAssertEqual(image.name, "clipboard.jpg")
        XCTAssertEqual(image.mime, "image/jpeg")
        XCTAssertEqual(image.bytesBase64, jpeg.base64EncodedString())
        XCTAssertEqual(image.bytes, jpeg)

        pasteboard.data.removeAll()
        XCTAssertNil(service.readImage())
    }

    func testReadFilesNormalizesAbsolutePathsAndPreservesOrder() throws {
        let pasteboard = FakePasteboard()
        pasteboard.urls = [
            URL(fileURLWithPath: "/tmp/../tmp/first image.png"),
            URL(fileURLWithPath: "/var/./second.txt"),
        ]
        let service = ClipboardService(pasteboard: pasteboard)
        XCTAssertEqual(
            try service.readFiles(),
            ["/tmp/first image.png", "/var/second.txt"]
        )
    }

    func testReadFilesRejectsRelativeAndUnsafePaths() {
        let pasteboard = FakePasteboard()
        pasteboard.urls = [URL(string: "relative.txt")!]
        let service = ClipboardService(pasteboard: pasteboard)
        XCTAssertThrowsError(try service.readFiles()) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidFileURL)
        }

        pasteboard.urls = [URL(fileURLWithPath: "/tmp/unsafe\nname")]
        XCTAssertThrowsError(try service.readFiles()) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidFileURL)
        }
    }
}

private actor RecordingUploadClient: URLSessionClient {
    enum Failure: Error, Equatable, Sendable {
        case network
        case timedOut
    }

    private let responseData: Data
    private let statusCode: Int
    private let failure: Failure?
    private(set) var request: URLRequest?
    private(set) var body: Data?

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
        self.failure = nil
    }

    init(failure: Failure) {
        self.responseData = Data()
        self.statusCode = 200
        self.failure = failure
    }

    func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        self.request = request
        self.body = body
        if let failure {
            if failure == .timedOut { throw URLError(.timedOut) }
            throw failure
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}

private func assertUploadThrows<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an upload error")
    } catch {
        handler(error)
    }
}

@MainActor
private final class FakePasteboard: PasteboardClient {
    var strings: [String: String] = [:]
    var data: [String: Data] = [:]
    var urls: [URL] = []

    func string(forType type: String) -> String? { strings[type] }
    func data(forType type: String) -> Data? { data[type] }
    func fileURLs() -> [URL] { urls }
}
