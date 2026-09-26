import CorralContracts

public extension SessionLinkProtocol {
    /// The sole terminal-byte uplink helper accepts user-originated bytes, never VT auto-replies.
    func sendUserInput(_ input: UserInputBytes, to sessionID: SessionID) async throws {
        try await send(.input(sessionID: sessionID, bytes: input))
    }
}
