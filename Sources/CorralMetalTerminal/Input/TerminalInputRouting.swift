import CorralContracts

/// Maps native/user intent into the server-supported v1 command form without feeding it to the local VT engine.
public protocol TerminalIntentEncoding: Sendable {
    func encode(_ input: TerminalInput) throws -> ClientInputPayload
}
