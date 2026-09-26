import CorralContracts

public extension SessionLinkProtocol {
    /// User input is a sequenced client command; server-only control messages and engine effects are not accepted.
    func sendUserInput(_ request: ClientInputRequest) async throws -> CommandSendReceipt {
        try await send(.input(request))
    }
}
