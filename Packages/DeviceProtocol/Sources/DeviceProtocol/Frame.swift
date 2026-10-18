import Foundation

public enum CRC16 {
    public static func modbus(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }
}

public struct Frame: Equatable, Sendable {
    public let command: UInt16
    public let operation: UInt8
    public let payload: [UInt8]
    public let control: UInt16
    public init(command: UInt16, operation: UInt8 = 0, payload: [UInt8] = [], control: UInt16 = 0x0160) {
        precondition(payload.count <= 65535)
        self.command = command; self.operation = operation; self.payload = payload; self.control = control
    }
    public var status: UInt8 { UInt8(control & 0x1f) }
    public var hasCRC: Bool { control & 0x20 != 0 }
    public var responseCommand: UInt16 { command & 0x7fff }
    public var encoded: [UInt8] {
        let body: [UInt8] = [0x55, UInt8(truncatingIfNeeded: control), UInt8(control >> 8), UInt8(truncatingIfNeeded: command), UInt8(command >> 8), UInt8(truncatingIfNeeded: payload.count), UInt8(payload.count >> 8), operation] + payload
        guard hasCRC else { return body }
        let crc = CRC16.modbus(body)
        return body + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
    }
}

/// APK Message format: 16-bit control/length, optional CRC indicated by control bit
/// 0x20. Storage is bounded to one 65,545-byte frame, independent of read boundaries.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public private(set) var rejectedPackets = 0
    private let maximumPayload: Int
    public init(maximumPayload: Int = 65535) { self.maximumPayload = max(0, min(65535, maximumPayload)) }
    public mutating func append(_ bytes: [UInt8]) -> [Frame] {
        var frames: [Frame] = []
        for byte in bytes {
            buffer.append(byte)
            while !buffer.isEmpty {
                guard buffer[0] == 0x55 else { buffer.removeFirst(); continue }
                guard buffer.count >= 3 else { break }
                // Type 1 is the web/Ear route; native B170 also uses type 6.
                guard buffer[2] == 1 || buffer[2] == 6 else { buffer.removeFirst(); continue }
                guard buffer.count >= 8 else { break }
                let length = Int(buffer[5]) + (Int(buffer[6]) << 8)
                guard length <= maximumPayload else { rejectedPackets += 1; buffer.removeFirst(); continue }
                let control = UInt16(buffer[1]) | UInt16(buffer[2]) << 8
                let hasCRC = control & 0x20 != 0
                let total = length + 8 + (hasCRC ? 2 : 0)
                guard buffer.count >= total else { break }
                let packet = Array(buffer.prefix(total))
                if hasCRC {
                    let expected = UInt16(packet[total - 2]) | UInt16(packet[total - 1]) << 8
                    guard CRC16.modbus(packet.dropLast(2)) == expected else {
                        rejectedPackets += 1; buffer.removeFirst(); continue
                    }
                }
                frames.append(Frame(command: UInt16(packet[3]) | UInt16(packet[4]) << 8,
                                    operation: packet[7], payload: Array(packet[8..<(8 + length)]), control: control))
                buffer.removeFirst(total)
            }
        }
        return frames
    }
    public mutating func reset() { buffer.removeAll(); rejectedPackets = 0 }
}

/// Read-only route negotiation for B170. Nonempty command payloads are never
/// prefixed with an endpoint, including all setters and ANC's explicit selector.
public enum FrameRoute: String, CaseIterable, Sendable {
    case web, nativeHeadphone, genericHeadphone
    public var control: UInt16 { self == .nativeHeadphone ? 0x0660 : 0x0160 }
    public func payload(command: UInt16, bytes: [UInt8]) -> [UInt8] {
        let payload = bytes.isEmpty ? Command.readPayload(command) : bytes
        return payload.isEmpty && self == .genericHeadphone ? [6] : payload
    }
    public static func candidates(base: String) -> [FrameRoute] {
        ModelRules.includes("alternateFrameRoutes", base) ? [.web, .nativeHeadphone, .genericHeadphone] : [.web]
    }
}

public enum Command {
    public static let customEQ: UInt16 = 49220, advancedBands: UInt16 = 49229
    public static let setCustomEQ: UInt16 = 61505, setAdvancedBands: UInt16 = 61520
    public static let battery: UInt16 = 49159, firmware: UInt16 = 49218, anc: UInt16 = 49182
    public static let eq: UInt16 = 49183, listeningMode: UInt16 = 49232, inEar: UInt16 = 49166
    public static let latency: UInt16 = 49217, bass: UInt16 = 49230, personalizedANC: UInt16 = 49184
    public static let dual: UInt16 = 49191, spatial: UInt16 = 49231, advancedEQ: UInt16 = 49228
    public static let flatEQ: UInt16 = 49256, codec: UInt16 = 49193, longPower: UInt16 = 49255, antiLeakage: UInt16 = 49265
    public static let setANC: UInt16 = 61455, setEQ: UInt16 = 61456, setListeningMode: UInt16 = 61469
    public static let setInEar: UInt16 = 61444, setLatency: UInt16 = 61504, setBass: UInt16 = 61521
    public static let ring: UInt16 = 61442, setPersonalizedANC: UInt16 = 61457, setDual: UInt16 = 61466
    public static let setSpatial: UInt16 = 61522, setAdvancedEQ: UInt16 = 61519, utc: UInt16 = 61450
    public static let setCodec: UInt16 = 61468, dualList: UInt16 = 49192, setDualDevice: UInt16 = 61467
    public static let mimi: UInt16 = 49186, audiodo: UInt16 = 49242
    public static let setMimi: UInt16 = 61461, setAudiodo: UInt16 = 61532, earFit: UInt16 = 61460
    public static let handshake: UInt16 = 49153, supportedFeatures: UInt16 = 49165, exclusion: UInt16 = 49250
    /// APK builders supply a one-byte selector for current + remembered ANC.
    public static func readPayload(_ command: UInt16) -> [UInt8] { command == anc ? [3] : command == advancedBands ? [255, 0] : [] }
}
