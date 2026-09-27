import CorralContracts
import Foundation

public struct AgentMirrorHTTPCodec: Sendable {
    public static let identifyRequestBodyLimit = 1_024

    public init() {}

    public func encodeIdentifyRequest(_ request: AgentMirrorIdentifyRequest) throws -> Data {
        guard request.version == 1 else { throw V1ControlCodecError.unsupportedVersion(request.version) }
        let nonce = Array(request.nonce.utf8)
        guard nonce.count == 32, nonce.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw V1ControlCodecError.invalidField("nonce")
        }
        guard isDestinationIPv4(request.destinationIP) else { throw V1ControlCodecError.invalidField("dest_ip") }
        let body = try JSONEncoder().encode(request)
        guard body.count <= Self.identifyRequestBodyLimit else { throw V1ControlCodecError.payloadTooLarge }
        return body
    }

    public func decodeWhoAmIResponse(_ data: Data) throws -> AgentMirrorWhoAmIResponse {
        let response = try JSONDecoder().decode(AgentMirrorWhoAmIResponse.self, from: data)
        guard response.version == 1 else { throw V1ControlCodecError.unsupportedVersion(response.version) }
        guard !response.hostID.isEmpty, response.port > 0 else { throw V1ControlCodecError.invalidField("whoami") }
        return response
    }

    public func decodeIdentifyResponse(_ data: Data) throws -> AgentMirrorIdentifyResponse {
        let response = try JSONDecoder().decode(AgentMirrorIdentifyResponse.self, from: data)
        guard response.version == 1 else { throw V1ControlCodecError.unsupportedVersion(response.version) }
        guard !response.hostID.isEmpty, !response.bound.isEmpty,
              response.mac.utf8.count == 64,
              response.mac.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw V1ControlCodecError.invalidField("identify response")
        }
        return response
    }

    public func decodeUploadResponse(_ data: Data) throws -> AgentMirrorUploadResponse {
        let response = try JSONDecoder().decode(AgentMirrorUploadResponse.self, from: data)
        guard response.path.hasPrefix("/") else { throw V1ControlCodecError.invalidField("upload.path") }
        return response
    }

    public func decodeError(_ data: Data) throws -> AgentMirrorHTTPError {
        try JSONDecoder().decode(AgentMirrorHTTPError.self, from: data)
    }

    private func isDestinationIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4, octets[0] != 127 else { return false }
        return octets.contains(where: { $0 != 0 })
    }
}
