import CorralContracts
import CorralProtocol
import Foundation
import XCTest

final class ConversationHistoryClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func client(status: Int, body: String, recorder: Recorder) -> ConversationHistoryClient {
        ConversationHistoryClient { request in
            recorder.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let request = ConversationHistoryRequest(reference: try! SessionReference("sock\u{1F}%1"), viewID: "v1", requestID: "h-1",
                                                     operation: .body, cursor: "tok", bodyRef: "live:abc")

    func testRequestUsesTheActiveRouteBearerAndOnlyContractFields() async throws {
        let recorder = Recorder()
        let page = #"{"request_id":"h-1","view_id":"v1","source_epoch":"e","snapshot_seq":3,"items":[],"has_more_before":false,"has_more_after":false,"history_support":"complete","source_omitted":false,"body_ref":"live:abc","body":"hello","body_complete":true}"#
        let route = try ApprovedEndpoint(scheme: "ws", host: "10.0.0.8", port: 52000, pairingHostID: "host-0001")
        let result = try await client(status: 200, body: page, recorder: recorder).fetch(request, route: route, token: "secret")
        XCTAssertEqual(result.body, "hello")
        XCTAssertTrue(result.bodyComplete)
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://10.0.0.8:52000/conversation/history")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(json, ["ref": "sock\u{1F}%1", "view_id": "v1", "request_id": "h-1", "op": "body", "cursor": "tok", "body_ref": "live:abc"])
        XCTAssertNil(sent.url?.query, "no query token is ever used")
    }

    func testClosedLocalErrorsAndForeignResponsesStayLocal() async throws {
        let route = try ApprovedEndpoint(host: "127.0.0.1", port: 52001)
        do {
            _ = try await client(status: 409, body: #"{"request_id":"h-1","view_id":"v1","error":"stale_view"}"#, recorder: Recorder()).fetch(request, route: route, token: "t")
            XCTFail("expected failure")
        } catch let failure as ConversationHistoryFailure {
            XCTAssertEqual(failure.code, "stale_view")
            XCTAssertTrue(failure.retiresView)
        }
        do {
            _ = try await client(status: 503, body: #"{"error":"busy"}"#, recorder: Recorder()).fetch(request, route: route, token: "t")
            XCTFail("expected failure")
        } catch let failure as ConversationHistoryFailure {
            XCTAssertEqual(failure.code, "busy")
            XCTAssertFalse(failure.retiresView, "busy is a local retry, not a dead view")
        }
        let foreign = #"{"request_id":"h-9","view_id":"v1","source_epoch":"e","snapshot_seq":3,"items":[],"history_support":"complete"}"#
        do {
            _ = try await client(status: 200, body: foreign, recorder: Recorder()).fetch(request, route: route, token: "t")
            XCTFail("a response for another request must not be adopted")
        } catch let failure as ConversationHistoryFailure {
            XCTAssertEqual(failure.code, "stale_view")
        }
    }
}
