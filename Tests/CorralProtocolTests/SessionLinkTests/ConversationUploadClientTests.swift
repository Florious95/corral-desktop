import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class ConversationUploadClientTests: XCTestCase {
    func testMultipartUsesPairedRouteBearerAndExactBytesWithoutInjection() throws {
        let route = try ApprovedEndpoint(scheme: "wss", host: "::1", port: 54001, pairingHostID: "host-private")
        let content = Data("中文\r\n\r🙂\n'\u{0000}".utf8)
        let request = try ConversationUploadClient.request(data: content, filename: "text\"\r\nheader.txt", route: route, token: "private-token", boundary: "test-boundary")
        XCTAssertEqual(request.url?.absoluteString, "https://[::1]:54001/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-token")
        let data = try XCTUnwrap(request.httpBody)
        let prefix = Data("--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"text___header.txt\"\r\nContent-Type: text/plain\r\n\r\n".utf8)
        XCTAssertEqual(data, prefix + content + Data("\r\n--test-boundary--\r\n".utf8))
        XCTAssertThrowsError(try ConversationUploadClient.request(data: Data(), filename: "empty", route: route, token: "t"))
        XCTAssertThrowsError(try ConversationUploadClient.request(data: Data([1]), filename: "f", route: route, token: ""))
        XCTAssertThrowsError(try ConversationUploadClient.request(data: Data(repeating: 1, count: ConversationUploadClient.maximumFileBytes + 1), filename: "large", route: route, token: "t"))
    }

    func testFileUploadUsesActualBytesAndRejectsHTTPOrInvalidPath() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("corral-upload-test-" + UUID().uuidString + ".txt")
        let exact = Data("原样 UTF-8\r\n末尾不补换行🙂".utf8)
        try exact.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let route = try ApprovedEndpoint(host: "127.0.0.1", port: 54002)
        let client = ConversationUploadClient { request in
            XCTAssertNotNil(request.httpBody?.range(of: exact))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
            return (Data(#"{"path":"/private/uploads/a b.txt"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await client.upload(file: file, route: route, token: "t")
        XCTAssertEqual(result, "/private/uploads/a b.txt")
        for (status, body) in [(401, "token rejected"), (507, "storage unavailable"), (200, #"{"path":"relative.txt"}"#), (200, #"{"path":"/uploads/x\nrun"}"#), (200, "{}")] {
            let failed = ConversationUploadClient { request in (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await failed.upload(file: file, route: route, token: "t"); XCTFail("accepted invalid upload result") }
            catch is ConversationUploadFailure {} // Fixed categories, never response text/credentials.
        }
    }

    func testOrdinaryFilesAreReferencesNotImagesOrExecutableCommands() {
        XCTAssertEqual(ConversationUploadClient.fileReference("/home/log files/user's.txt"), "'/home/log files/user'\\''s.txt'")
        XCTAssertFalse(ConversationUploadClient.validPath("https://elsewhere/file"))
        XCTAssertFalse(ConversationUploadClient.validPath("/tmp/unsafe\u{001B}"))
        XCTAssertTrue(ConversationUploadClient.validPath("/tmp/中文 file.txt"))
    }
}
