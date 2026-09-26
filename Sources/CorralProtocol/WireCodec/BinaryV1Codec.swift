import CorralContracts
import Foundation

public struct BinaryV1Codec: BinaryFrameCodecProtocol {
    public init() {}

    public func encodeBinaryFrame(_ frame: BinaryFrame) throws -> Data {
        let reference = Array(frame.reference.rawValue.utf8)
        guard !reference.isEmpty else { throw ProtocolContractError.invalidReference }
        guard reference.count <= ProtocolV1.maximumReferenceBytes else { throw ProtocolContractError.referenceTooLong }
        guard frame.ansi.count <= ProtocolV1.maximumANSIBytes else { throw ProtocolContractError.payloadTooLarge }

        var encoded = Data(ProtocolV1.magic)
        encoded.append(ProtocolV1.version)
        encoded.append(frame.kind.rawValue)
        encoded.append(UInt8(reference.count))
        encoded.append(contentsOf: reference)
        switch frame {
        case .snapshot, .delta:
            encoded.append(contentsOf: frame.ansi)
        case let .scrollback(_, metadata, ansi):
            Self.appendBigEndian(metadata.requestID, to: &encoded)
            Self.appendBigEndian(UInt32(bitPattern: metadata.fromLine), to: &encoded)
            Self.appendBigEndian(metadata.lineCount, to: &encoded)
            encoded.append(contentsOf: ansi)
        }
        return encoded
    }

    public func decodeBinaryFrame(_ data: Data) throws -> BinaryFrame {
        let maximumFrameBytes = ProtocolV1.headerByteCount + ProtocolV1.maximumReferenceBytes +
            ProtocolV1.scrollbackMetadataByteCount + ProtocolV1.maximumANSIBytes
        guard data.count <= maximumFrameBytes else { throw ProtocolContractError.payloadTooLarge }
        guard data.count >= ProtocolV1.headerByteCount else { throw ProtocolContractError.truncatedFrame }

        return try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= ProtocolV1.headerByteCount else { throw ProtocolContractError.truncatedFrame }
            guard bytes[0] == ProtocolV1.magic[0], bytes[1] == ProtocolV1.magic[1] else {
                throw ProtocolContractError.invalidMagic
            }
            guard bytes[2] == ProtocolV1.version else { throw ProtocolContractError.unsupportedVersion(bytes[2]) }
            guard let kind = FrameKind(rawValue: bytes[3]) else { throw ProtocolContractError.unknownFrameKind(bytes[3]) }

            let referenceLength = Int(bytes[4])
            guard referenceLength > 0 else { throw ProtocolContractError.invalidReference }
            let (payloadStart, overflow) = ProtocolV1.headerByteCount.addingReportingOverflow(referenceLength)
            guard !overflow, payloadStart <= bytes.count else { throw ProtocolContractError.truncatedFrame }
            let referenceData = data.subdata(in: ProtocolV1.headerByteCount..<payloadStart)
            guard let referenceString = String(data: referenceData, encoding: .utf8) else {
                throw ProtocolContractError.invalidReference
            }
            let reference = try SessionReference(referenceString)

            switch kind {
            case .snapshot, .delta:
                let ansiLength = bytes.count - payloadStart
                guard ansiLength <= ProtocolV1.maximumANSIBytes else { throw ProtocolContractError.payloadTooLarge }
                let ansi = data.subdata(in: payloadStart..<bytes.count)
                return kind == .snapshot
                    ? .snapshot(reference: reference, ansi: ansi)
                    : .delta(reference: reference, ansi: ansi)
            case .scrollback:
                let (ansiStart, headerOverflow) = payloadStart.addingReportingOverflow(ProtocolV1.scrollbackMetadataByteCount)
                guard !headerOverflow, ansiStart <= bytes.count else { throw ProtocolContractError.truncatedFrame }
                let requestID = Self.readUInt32(bytes, at: payloadStart)
                let fromLine = Int32(bitPattern: Self.readUInt32(bytes, at: payloadStart + 4))
                let lineCount = Self.readUInt32(bytes, at: payloadStart + 8)
                let metadata = try ScrollbackMetadata(requestID: requestID, fromLine: fromLine, lineCount: lineCount)
                let ansiLength = bytes.count - ansiStart
                guard ansiLength <= ProtocolV1.maximumANSIBytes else { throw ProtocolContractError.payloadTooLarge }
                return .scrollback(reference: reference, metadata: metadata, ansi: data.subdata(in: ansiStart..<bytes.count))
            }
        }
    }

    private static func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
