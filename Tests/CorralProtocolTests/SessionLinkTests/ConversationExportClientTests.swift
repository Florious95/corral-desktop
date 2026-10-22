import CorralContracts
import Foundation
import Network
import XCTest
@testable import CorralProtocol

final class ConversationExportClientTests: XCTestCase {
    private let ref = try! SessionReference("socket\u{1F}%7")

    func testRequestBindsCurrentRouteRefSIDAndBearerWithoutPathInjection() throws {
        let route = try ApprovedEndpoint(scheme: "wss", host: "10.0.0.8", port: 52000, pairingHostID: "host-0001")
        let request = try ConversationExportClient.request(reference: ref, sessionID: "native-id", route: route, token: "paired-secret")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/artifacts/native-id/export")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "ref", value: ref.rawValue)])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer paired-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("paired-secret"))
        for sid in ["", "../secret", "/file", "a\\b", "-flag", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(try ConversationExportClient.request(reference: ref, sessionID: sid, route: route, token: "t"))
        }
    }

    func testRealBoundedHTTPDownloadPreservesOfficialHTMLAndAtomicallySaves() async throws {
        let html = Data("<!doctype html><html><body>官方会话 👋<script>native()</script></body></html>".utf8)
        let server = try ExportHTTPFixture(status: "200 OK", headers: "Content-Type: text/html; charset=utf-8\r\n", body: html)
        try await server.start(); defer { server.stop() }
        let artifact = try await ConversationExportClient().download(reference: ref, sessionID: "sid", route: try ApprovedEndpoint(host: "127.0.0.1", port: server.port), token: "test-only-token")
        defer { artifact.remove() }
        XCTAssertEqual(try Data(contentsOf: artifact.file), html)
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("corral-export-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }
        let destination = destinationDirectory.appendingPathComponent("saved.html")
        try Data("old file".utf8).write(to: destination)
        try artifact.save(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), html)
        let requests = await server.requests.values
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].lowercased().contains("authorization: bearer test-only-token"))
        XCTAssertFalse(requests[0].contains("Range:"))
        artifact.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.file.path))
    }

    func testRealHTTPRejectsRedirectWrongFormatEmptyAndOversizedResponseWithoutRetry() async throws {
        for (status, headers, body, code) in [
            ("302 Found", "Location: https://example.invalid/steal\r\nContent-Type: text/html\r\n", Data(), "http_failed"),
            ("401 Unauthorized", "Content-Type: application/json\r\n", Data("{}".utf8), "http_failed"),
            ("200 OK", "Content-Type: text/markdown\r\n", Data("not HTML".utf8), "unexpected_format"),
            ("200 OK", "Content-Type: text/html\r\n", Data(), "empty"),
            ("200 OK", "Content-Type: text/html\r\nContent-Length: 67108865\r\n", Data(), "too_large")
        ] {
            let server = try ExportHTTPFixture(status: status, headers: headers, body: body)
            try await server.start(); defer { server.stop() }
            do {
                let artifact = try await ConversationExportClient().download(reference: ref, sessionID: "sid", route: try ApprovedEndpoint(host: "127.0.0.1", port: server.port), token: "test-only-token")
                artifact.remove(); XCTFail("Unexpected export success: \(code)")
            } catch let failure as ConversationExportFailure { XCTAssertEqual(failure.code, code) }
            let requests = await server.requests.values
            XCTAssertEqual(requests.count, 1, "No redirect or automatic retry")
        }
    }
}

private actor ExportRequests {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

/// Loopback-only HTTP fixture, not a provider or exporter substitute. Production bytes(for:) and redirects execute unchanged.
private final class ExportHTTPFixture: @unchecked Sendable {
    let requests = ExportRequests()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "corral.export.fixture")
    private let response: Data
    private(set) var port: Int = 0
    init(status: String, headers: String, body: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        response = Data("HTTP/1.1 \(status)\r\n\(headers)Connection: close\r\n\r\n".utf8) + body
    }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
                guard let self, let data else { connection.cancel(); return }
                Task {
                    await self.requests.record(String(decoding: data, as: UTF8.self))
                    connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if case .ready = listener.state, let port = listener.port { self.port = Int(port.rawValue); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }
    func stop() { listener.cancel() }
}
