import Foundation
import XCTest
@testable import Shell

final class LocalContentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmirror-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("0123456789".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data([0, 1, 2, 3, 4, 5]).write(to: root.appendingPathComponent("asset.wasm"))
        try Data("console.log('ok');".utf8).write(to: root.appendingPathComponent("entry.js"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ method: String = "GET", _ url: String = "agentmirror://app/index.html",
                         headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    func testResponsesUseHTTPStatusHeadersAndSingleRanges() throws {
        let content = try LocalContent(distURL: root)
        let full = content.responsePlan(for: request())
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(full.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(full.headers["Content-Length"], "10")
        XCTAssertEqual(full.range?.count, 10)

        let partial = content.responsePlan(for: request(headers: ["Range": "bytes=2-5"]))
        XCTAssertEqual(partial.statusCode, 206)
        XCTAssertEqual(partial.headers["Content-Range"], "bytes 2-5/10")
        XCTAssertEqual(partial.headers["Content-Length"], "4")
        XCTAssertEqual(partial.range, 2..<6)

        let suffix = content.responsePlan(for: request(headers: ["Range": "bytes=-3"]))
        XCTAssertEqual(suffix.statusCode, 206)
        XCTAssertEqual(suffix.range, 7..<10)

        let multi = content.responsePlan(for: request(headers: ["Range": "bytes=0-1,4-5"]))
        XCTAssertEqual(multi.statusCode, 200)
        XCTAssertNil(multi.headers["Content-Range"])

        let head = content.responsePlan(for: request("HEAD"))
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertFalse(head.bodyAllowed)
    }

    func testMissingMalformedAndBinaryResourcesHaveSafeResponses() throws {
        let content = try LocalContent(distURL: root)
        let missing = content.responsePlan(for: request("GET", "agentmirror://app/nope.js"))
        XCTAssertEqual(missing.statusCode, 404)
        XCTAssertEqual(missing.headers["Content-Length"], "0")

        let malformed = content.responsePlan(for: request(headers: ["Range": "bytes=nope"]))
        XCTAssertEqual(malformed.statusCode, 400)

        let unsatisfiable = content.responsePlan(for: request(headers: ["Range": "bytes=100-"]))
        XCTAssertEqual(unsatisfiable.statusCode, 416)
        XCTAssertEqual(unsatisfiable.headers["Content-Range"], "bytes */10")

        let binary = content.responsePlan(for: request("GET", "agentmirror://app/asset.wasm"))
        XCTAssertEqual(binary.statusCode, 200)
        XCTAssertEqual(binary.headers["Content-Type"], "application/wasm")
        XCTAssertNil(binary.headers["Content-Type"]?.range(of: "charset"))

        let unsupported = content.responsePlan(for: request("POST"))
        XCTAssertEqual(unsupported.statusCode, 405)
        XCTAssertEqual(unsupported.headers["Allow"], "GET, HEAD")
    }

    func testManifestRejectsTraversalAndSymlinkEscape() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("agentmirror-outside-\(UUID().uuidString).js")
        try Data("must not serve".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.js"),
                                                   withDestinationURL: outside)
        let content = try LocalContent(distURL: root)
        XCTAssertThrowsError(try content.file(for: URL(string: "agentmirror://app/escape.js")!))
        XCTAssertThrowsError(try content.file(for: URL(string: "agentmirror://app/../index.html")!))
        XCTAssertThrowsError(try content.file(for: URL(string: "https://app/index.html")!))
        XCTAssertTrue(LocalContent.isEntry(URL(string: "agentmirror://app/index.html#route")))
        XCTAssertFalse(LocalContent.isEntry(URL(string: "agentmirror://app/index.html?cache=1")))
    }
}
