import CorralContracts

/// Only explicit user-originated bytes may cross this route; TerminalAutoReplyBytes are not accepted.
public protocol TerminalInputRouting: Sendable {
    func route(_ input: UserInputBytes, to sessionID: SessionID) async throws
}
