import AppKit
import CorralContracts
import CorralProtocol
import CorralServices
import CorralUI
import Foundation
import XCTest
@testable import CorralApp
@testable import SwiftTerm

/// Pi runs with any-event mouse tracking, so dragging its scrollbar is a stream of SGR motion
/// reports. Core injects each input message serially (two tmux commands each); a 120 Hz drag
/// must not leave stale positions queued behind the pointer once the hand stops.
@MainActor
final class PointerMotionBackpressureTests: XCTestCase {
    func testFastDragKeepsAtMostOneMotionAtTheServerAndEndsOnTheReleasePosition() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-motion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("workspace", isDirectory: true)
        let store = try CorralWorkspaceStore(applicationSupportDirectory: support)
        let preferences = try UserPreferencesStore(applicationSupportDirectory: support)
        let deviceID = DeviceID("corral-native-development-endpoint")
        let reference = try SessionReference("motion-session")
        let sessionID = SessionID("\(deviceID.rawValue.utf8.count):\(deviceID.rawValue)\(reference.rawValue)")
        _ = try await store.smartOpenSession(sessionID, gesture: .doubleClick)

        let server = SlowInputSessionLink(perInput: .milliseconds(30))
        let coordinator = CorralApplicationCoordinator(
            deviceRepository: MotionEmptyDeviceRepository(),
            credentialVault: MotionEmptyCredentialVault(),
            sessionLink: server,
            deviceSessionLifecycle: CoordinatorDeviceSessionLifecycle(sessionLink: server),
            workspaceStore: store,
            userPreferencesStore: preferences,
            initialWorkspaceState: await store.snapshot(),
            initialUserPreferences: await preferences.snapshot(),
            environment: ["CORRAL_NATIVE_ENDPOINT": "ws://127.0.0.1:9919/ws",
                          "CORRAL_NATIVE_TOKEN": "motion-test-only", "CORRAL_NATIVE_BACKGROUND": "1"]
        )
        let window = try XCTUnwrap(coordinator.windowController.window)
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 1_000, height: 700), display: true, animate: false)
        window.orderBack(nil)
        await coordinator.start()
        try await server.emit(.control(.listing(SessionListing(requestID: 1, sequence: 1, workspaces: [
            WorkspaceRecord(workingDirectory: "/fixture/motion", sessionCount: 1, aggregateState: .idle, sessions: [
                WireSessionRecord(reference: reference, name: "pi", workingDirectory: "/fixture/motion",
                                  state: .idle, rows: 24, columns: 80)
            ])
        ]))))
        let subscribed = await waitUntil { coordinator.subscribedSessionIDs.contains(reference.rawValue) }
        XCTAssertTrue(subscribed)
        let view = try XCTUnwrap(coordinator.terminalView(for: reference))
        // Pi's mode: alternate screen, any-event motion tracking, SGR encoding.
        try await server.emit(.frame(.delta(reference: reference, ansi: Data("\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h".utf8))))
        let tracking = await waitUntil { view.getTerminal().mouseMode == .anyEvent }
        XCTAssertTrue(tracking)

        func event(_ type: NSEvent.EventType, _ progress: Double) -> NSEvent {
            let point = CGPoint(x: view.bounds.width * (0.05 + 0.85 * progress), y: view.bounds.height * (0.9 - 0.8 * progress))
            return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let drags = 120
        view.mouseDown(with: event(.leftMouseDown, 0))
        XCTAssertTrue(window.firstResponder === view)
        for index in 1...drags {
            try await Task.sleep(for: .milliseconds(8))
            view.mouseDragged(with: event(.leftMouseDragged, Double(index) / Double(drags)))
        }
        view.mouseUp(with: event(.leftMouseUp, 1))
        let released = ContinuousClock.now
        let drained = await waitUntil(timeout: .seconds(20)) {
            let reports = await server.processedReports()
            let idle = await server.isIdle()
            return idle && reports.last.flatMap(SGRReport.init)?.isRelease == true
        }
        XCTAssertTrue(drained)
        let processed = await server.processedReports()
        let lastProcessed = await server.lastProcessedAt()
        let tail = lastProcessed.map { max(.zero, $0 - released) } ?? .zero

        let reports = processed.compactMap(SGRReport.init)
        let motions = reports.filter(\.isMotion)
        XCTAssertEqual(reports.first.map { !$0.isMotion && $0.isPress }, true, "the press must reach the PTY first")
        XCTAssertEqual(reports.last?.isRelease, true, "the release must reach the PTY last")
        XCTAssertEqual(motions.last?.cell, reports.last?.cell, "the newest pointer position must reach the PTY before the release")
        XCTAssertLessThan(motions.count, drags / 2, "stale intermediate positions must be superseded while the server is busy")
        XCTAssertLessThan(tail, .milliseconds(250), "after the hand stops the PTY must stop within one server turnaround; tail=\(tail)")
        let statistics = coordinator.pointerMotionStatistics
        XCTAssertGreaterThan(statistics.superseded, 0)
        XCTAssertEqual(statistics.sent, motions.count)

        // A new selection/scrollbar gesture can end at the same cell as the previous one.
        let beforeNextGesture = await server.processedReports().count
        view.mouseDown(with: event(.leftMouseDown, 0))
        view.mouseDragged(with: event(.leftMouseDragged, 1))
        view.mouseUp(with: event(.leftMouseUp, 1))
        _ = await waitUntil(timeout: .seconds(1)) {
            let reports = await server.processedReports()
            return reports.count >= beforeNextGesture + 3 && reports.last.flatMap(SGRReport.init)?.isRelease == true
        }
        let nextGesture = await server.processedReports().dropFirst(beforeNextGesture).compactMap(SGRReport.init)
        XCTAssertEqual(nextGesture.count, 3, "Deduplication must not cross a press/release barrier")
        XCTAssertEqual(nextGesture.filter(\.isMotion).count, 1)

        // Literal pasted/typed ESC bytes are not physical pointer motion.
        let literal = Data("\u{1b}[<32;7;7M".utf8)
        let beforeLiteral = await server.processedReports().count
        for _ in 0..<3 { view.send(data: Array(literal)[...]) }
        _ = await waitUntil(timeout: .seconds(1)) { await server.processedReports().count >= beforeLiteral + 3 }
        let literals = await server.processedReports().dropFirst(beforeLiteral)
        XCTAssertEqual(Array(literals), [literal, literal, literal], "No text may be deduplicated by guessing its escape syntax")

        // A slow server must not turn the 250ms safety timer into a new fixed-rate producer.
        await server.setProcessingDelay(.milliseconds(500))
        view.mouseDown(with: event(.leftMouseDown, 0))
        for index in 1...120 {
            view.mouseDragged(with: event(.leftMouseDragged, Double(index) / 120))
            try await Task.sleep(for: .milliseconds(10))
        }
        let maximumOutstanding = await server.maximumOutstandingInputs()
        XCTAssertLessThanOrEqual(maximumOutstanding, 2, "Only the press and one motion may be awaiting slow server consumption")
        view.mouseUp(with: event(.leftMouseUp, 1))
        let slowDrained = await waitUntil(timeout: .seconds(5)) {
            let reports = await server.processedReports()
            let idle = await server.isIdle()
            return idle && reports.last.flatMap(SGRReport.init)?.isRelease == true
        }
        XCTAssertTrue(slowDrained)
        await coordinator.stop()
    }

    private func waitUntil(timeout: Duration = .seconds(8), _ predicate: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

private struct SGRReport {
    let code: Int
    let cell: [Int]
    let final: Character
    var isMotion: Bool { code & 32 != 0 }
    var isPress: Bool { final == "M" }
    var isRelease: Bool { final == "m" }

    init?(_ bytes: Data) {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.hasPrefix("\u{1b}[<"), let final = text.last, final == "M" || final == "m" else { return nil }
        let fields = text.dropFirst(3).dropLast().split(separator: ";").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        code = fields[0]
        cell = Array(fields[1...])
        self.final = final
    }
}

/// Acknowledges each input only after a fixed serial processing time, like Core's read loop.
private actor SlowInputSessionLink: SessionLinkProtocol {
    private let stream = MotionEventStream()
    private var perInput: Duration
    private var authenticated: AuthenticatedConnection?
    private var ordinal: UInt64 = 0
    private var serverFreeAt = ContinuousClock.now
    private var processed: [Data] = []
    private var processedAt: ContinuousClock.Instant?
    private var outstanding = 0
    private var maximumOutstanding = 0
    func setProcessingDelay(_ delay: Duration) { perInput = delay; maximumOutstanding = outstanding }
    func maximumOutstandingInputs() -> Int { maximumOutstanding }

    init(perInput: Duration) { self.perInput = perInput }

    func connect(to endpoint: ApprovedEndpoint, deviceID: DeviceID, credential: CredentialHandle) async throws -> AuthenticatedConnection {
        let connection = try AuthenticatedConnection(linkInstanceID: LinkInstanceID(), deviceID: deviceID, connectionEpoch: ConnectionEpoch(1))
        authenticated = connection
        return connection
    }

    func eventStream() async throws -> any SessionEventStream { stream }

    func send(_ command: ClientCommand) async throws -> CommandSendReceipt {
        switch command {
        case let .subscribe(reference, _):
            try await emit(.frame(.snapshot(reference: reference, ansi: Data())))
        case let .input(request):
            guard case let .bytes(bytes) = request.payload else { break }
            let due = max(ContinuousClock.now, serverFreeAt) + perInput
            serverFreeAt = due
            outstanding += 1
            maximumOutstanding = max(maximumOutstanding, outstanding)
            Task { await self.process(bytes, sequence: request.sequence, at: due) }
        default: break
        }
        let requestID: UInt32? = switch command {
        case let .list(id): id
        case let .input(request): request.sequence
        default: nil
        }
        return CommandSendReceipt(requestID: requestID, socketWritten: true)
    }

    private func process(_ bytes: Data, sequence: UInt32, at due: ContinuousClock.Instant) async {
        try? await Task.sleep(until: due)
        processed.append(bytes)
        processedAt = ContinuousClock.now
        outstanding -= 1
        try? await emit(.control(.inputAck(seq: sequence, ok: true, reason: nil)))
    }

    func disconnect() async {
        authenticated = nil
        await stream.finish()
    }

    func emit(_ event: SessionEvent) async throws {
        guard let authenticated else { throw SessionLinkFailure.disconnected }
        ordinal += 1
        let origin = SessionEventOrigin(linkInstanceID: authenticated.linkInstanceID, deviceID: authenticated.deviceID,
                                        connectionEpoch: authenticated.connectionEpoch, receiveOrdinal: ReceiveOrdinal(ordinal))
        try await stream.yield(SessionEventEnvelope(origin: origin, wireByteCount: 0, event: event))
    }

    func isIdle() -> Bool { outstanding == 0 }
    func processedReports() -> [Data] { processed }
    func lastProcessedAt() -> ContinuousClock.Instant? { processedAt }
}

private actor MotionEventStream: SessionEventStream {
    private var queued: [SessionEventEnvelope] = []
    private var waiter: CheckedContinuation<SessionEventEnvelope?, Never>?
    private var finished = false

    var budget: SessionEventStreamBudget {
        SessionEventStreamBudget(maximumBufferedBytes: 1_000_000, maximumBufferedEvents: 128, maximumBufferedControls: 32)
    }

    func next() async throws -> SessionEventEnvelope? {
        if !queued.isEmpty { return queued.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func yield(_ envelope: SessionEventEnvelope) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: envelope)
        } else {
            queued.append(envelope)
        }
    }

    func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

private actor MotionEmptyDeviceRepository: DeviceRepositoryProtocol {
    func listDevices() async throws -> [DeviceRecord] { [] }
    func save(_ device: DeviceRecord) async throws {}
    func delete(id: DeviceID) async throws {}
}

private actor MotionEmptyCredentialVault: DeviceCredentialVault {
    func store(_ secret: String, for handle: CredentialHandle) async throws {}
    func resolve(_ handle: CredentialHandle) async throws -> String? { nil }
    func delete(_ handle: CredentialHandle) async throws {}
}
