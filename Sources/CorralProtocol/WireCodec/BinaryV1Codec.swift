import CorralContracts
import Foundation

public struct BinaryV1Codec: WireCodecProtocol {
    public init() {}

    public func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data {
        let referenceLength = frame.reference.utf8.count
        guard referenceLength > 0 else { throw ProtocolContractError.invalidReference }
        guard referenceLength <= ProtocolV1.maximumReferenceBytes else {
            throw ProtocolContractError.referenceTooLong
        }
        guard !frame.payload.isEmpty else { throw ProtocolContractError.truncatedFrame }
        guard frame.payload.count <= ProtocolV1.maximumTerminalPayloadBytes else {
            throw ProtocolContractError.payloadTooLarge
        }

        var encoded = Data(capacity: ProtocolV1.headerByteCount + referenceLength + frame.payload.count)
        encoded.append(contentsOf: ProtocolV1.magic)
        encoded.append(ProtocolV1.version)
        encoded.append(frame.kind.rawValue)
        encoded.append(UInt8(referenceLength))
        encoded.append(contentsOf: frame.reference.utf8)
        encoded.append(contentsOf: frame.payload)
        return encoded
    }

    public func decodeBinaryFrame(_ data: Data) throws -> BinaryFrame {
        guard data.count >= ProtocolV1.headerByteCount else { throw ProtocolContractError.truncatedFrame }

        let start = data.startIndex
        let versionIndex = data.index(start, offsetBy: 2)
        let kindIndex = data.index(after: versionIndex)
        let lengthIndex = data.index(after: kindIndex)
        guard data[start] == ProtocolV1.magic[0], data[data.index(after: start)] == ProtocolV1.magic[1] else {
            throw ProtocolContractError.invalidMagic
        }
        let version = data[versionIndex]
        guard version == ProtocolV1.version else { throw ProtocolContractError.unsupportedVersion(version) }
        guard let kind = FrameKind(rawValue: data[kindIndex]) else {
            throw ProtocolContractError.unknownFrameKind(data[kindIndex])
        }

        let referenceLength = Int(data[lengthIndex])
        let referenceStart = data.index(after: lengthIndex)
        guard referenceLength <= data.distance(from: referenceStart, to: data.endIndex) else {
            throw ProtocolContractError.truncatedFrame
        }
        let payloadStart = data.index(referenceStart, offsetBy: referenceLength)
        guard payloadStart < data.endIndex else { throw ProtocolContractError.truncatedFrame }
        let referenceBytes = data[referenceStart..<payloadStart]
        guard let reference = String(data: referenceBytes, encoding: .utf8), !reference.isEmpty else {
            throw ProtocolContractError.invalidReference
        }
        let payloadCount = data.distance(from: payloadStart, to: data.endIndex)
        guard payloadCount <= ProtocolV1.maximumTerminalPayloadBytes else {
            throw ProtocolContractError.payloadTooLarge
        }

        return BinaryFrame(kind: kind, reference: reference, payload: data[payloadStart..<data.endIndex])
    }
}
