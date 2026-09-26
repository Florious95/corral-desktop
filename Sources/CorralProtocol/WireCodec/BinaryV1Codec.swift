import CorralContracts
import Foundation

public struct BinaryV1Codec: WireCodecProtocol {
    public init() {}

    public func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data {
        let reference = Array(frame.reference.utf8)
        guard reference.count <= ProtocolV1.maximumReferenceBytes else {
            throw ProtocolContractError.referenceTooLong
        }
        guard frame.payload.count <= ProtocolV1.maximumTerminalPayloadBytes else {
            throw ProtocolContractError.payloadTooLarge
        }

        var encoded = Data(ProtocolV1.magic)
        encoded.append(ProtocolV1.version)
        encoded.append(frame.kind.rawValue)
        encoded.append(UInt8(reference.count))
        encoded.append(contentsOf: reference)
        encoded.append(contentsOf: frame.payload)
        return encoded
    }

    public func decodeBinaryFrame(_ data: Data) throws -> BinaryFrame {
        let bytes = Array(data)
        guard bytes.count >= ProtocolV1.headerByteCount else { throw ProtocolContractError.truncatedFrame }
        guard Array(bytes[0..<2]) == ProtocolV1.magic else { throw ProtocolContractError.invalidMagic }
        guard bytes[2] == ProtocolV1.version else { throw ProtocolContractError.unsupportedVersion(bytes[2]) }
        guard let kind = FrameKind(rawValue: bytes[3]) else { throw ProtocolContractError.unknownFrameKind(bytes[3]) }

        let referenceLength = Int(bytes[4])
        let payloadStart = ProtocolV1.headerByteCount + referenceLength
        guard bytes.count >= payloadStart else { throw ProtocolContractError.truncatedFrame }
        guard bytes.count - payloadStart <= ProtocolV1.maximumTerminalPayloadBytes else {
            throw ProtocolContractError.payloadTooLarge
        }
        let referenceData = Data(bytes[ProtocolV1.headerByteCount..<payloadStart])
        guard let reference = String(data: referenceData, encoding: .utf8) else {
            throw ProtocolContractError.invalidReference
        }

        return BinaryFrame(kind: kind, reference: reference, payload: Data(bytes.dropFirst(payloadStart)))
    }
}
