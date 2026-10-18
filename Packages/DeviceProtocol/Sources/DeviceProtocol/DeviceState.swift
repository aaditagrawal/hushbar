import Foundation

public enum BatteryPart: UInt8, CaseIterable, Sendable {
    case left = 2, right = 3, chargingCase = 4, stereo = 6
    public var label: String {
        switch self { case .left: "Left"; case .right: "Right"; case .chargingCase: "Case"; case .stereo: "Device" }
    }
}
public struct Battery: Equatable, Sendable {
    public let percent: Int
    public let charging: Bool
    public init(percent: Int, charging: Bool) { self.percent = percent; self.charging = charging }
}
/// Names correspond to device_common.js levels 1...6, not the UI button indices.
public enum ANCMode: UInt8, CaseIterable, Sendable {
    case off = 5, transparency = 7, low = 3, high = 1, medium = 2, adaptive = 4
    public var label: String {
        switch self { case .off: "Off"; case .transparency: "Transparency"; case .low: "Low"; case .high: "High"; case .medium: "Medium"; case .adaptive: "Adaptive" }
    }
    public var payload: [UInt8] { [1, rawValue, 0] }
    public var isCancellation: Bool { self != .off && self != .transparency }
}
public struct AudioChoice: Equatable, Sendable, Identifiable {
    public let id: UInt8
    public let name: String
    public init(_ id: UInt8, _ name: String) { self.id = id; self.name = name }
}
public struct SpatialMode: Equatable, Sendable, Identifiable {
    public let id: Int, name: String, bit: Int, mode: UInt8, head: UInt8
    public static let all: [SpatialMode] = [
        .init(id: 0, name: "Off", bit: 0, mode: 0, head: 0),
        .init(id: 1, name: "Head tracked", bit: 1, mode: 1, head: 1),
        .init(id: 2, name: "Fixed", bit: 2, mode: 1, head: 0),
        .init(id: 3, name: "Concert", bit: 8, mode: 2, head: 0),
        .init(id: 4, name: "Theatre", bit: 16, mode: 3, head: 0),
        .init(id: 5, name: "Game", bit: 32, mode: 4, head: 0)
    ]
    public var payload: [UInt8] { [mode, head] }
}
public enum FitResult: UInt8, Sendable, CaseIterable {
    case good = 0, adjust = 1, unavailable = 2
    public var label: String { switch self { case .good: "Good seal"; case .adjust: "Adjust fit"; case .unavailable: "Insert earbud" } }
}
public struct DualDevice: Identifiable, Equatable, Sendable {
    public let address: [UInt8]
    public let name: String
    public let isSelf: Bool
    public var connected: Bool
    public var id: String { address.map { String(format: "%02X", $0) }.joined(separator: "-") }
    public init(address: [UInt8], name: String, isSelf: Bool, connected: Bool) {
        self.address = address; self.name = name; self.isSelf = isSelf; self.connected = connected
    }
    /// A page is parsed atomically: truncated names/records never replace good state.
    public static func page(_ p: [UInt8]) -> [DualDevice]? {
        guard p.count >= 3 else { return nil }
        var offset = 3
        var result: [DualDevice] = []
        for _ in 0..<Int(p[2]) {
            guard offset + 8 <= p.count else { return nil }
            let truncated = p[offset + 7] & 0x80 != 0
            let length = truncated ? 31 : Int(p[offset + 7] & 0x7f)
            guard offset + 8 + length <= p.count else { return nil }
            let name = String(decoding: p[(offset + 8)..<(offset + 8 + length)], as: UTF8.self)
            result.append(.init(address: Array(p[(offset + 1)..<(offset + 7)]), name: truncated ? name.replacingOccurrences(of: "�", with: "") + "…" : name, isSelf: p[offset] & 0xf0 == 0x10, connected: p[offset] & 0x0f == 1))
            offset += 8 + length
        }
        return result
    }
}
public struct DeviceState: Sendable, Equatable {
    public var batteries: [BatteryPart: Battery] = [:]
    public var customEQ: EqualizerProfile?, advancedBands: EqualizerProfile?
    public var firmware = ""
    public var anc: ANCMode?
    public var eq: UInt8?
    public var inEar: Bool?, latency: Bool?, bass: Bool?, personalizedANC: Bool?, dual: Bool?
    public var bassWire: UInt8 = 0
    public var spatial: Int?, advancedEQ: Bool?, flatEQ: Bool?, codec: UInt8?, longPower: Bool?, antiLeakage: UInt8?
    public var personalSound: Bool?
    public var fitLeft: FitResult?, fitRight: FitResult?
    public var dualDevices: [DualDevice] = []
    public var dualListSupported: Bool?
    public var exclusion: Bool?
    public var lastANC: ANCMode?
    public init() {}
    public var lowestBattery: Int? { batteries.values.map(\.percent).min() }
    public mutating func apply(_ frame: Frame) {
        guard frame.status == 0 else { return }
        let p = frame.payload
        switch frame.responseCommand {
        case 24577, 16391:
            guard let count = p.first, p.count >= 1 + Int(count) * 2 else { return }
            var next: [BatteryPart: Battery] = [:]
            for index in 0..<Int(count) {
                let offset = 1 + index * 2
                if let part = BatteryPart(rawValue: p[offset]), p[offset + 1] & 127 <= 100 {
                    next[part] = Battery(percent: Int(p[offset + 1] & 127), charging: p[offset + 1] & 128 != 0)
                }
            }
            batteries = next
        case 24579, 16414:
            // Firmware returns triples, possibly with last ANC before current mode.
            for offset in stride(from: 0, to: max(0, p.count - 1), by: 3) {
                guard let mode = ANCMode(rawValue: p[offset + 1]) else { continue }
                if p[offset] == 1 { anc = mode }
                if p[offset] == 2, mode.isCancellation { lastANC = mode }
            }
        case 16452: if let value = EqualizerProfile.decode(p, advanced: false) { customEQ = value }
        case 16461: if let value = EqualizerProfile.decode(p, advanced: true) { advancedBands = value }
        case 16415, 16464: eq = p.first
        case 16450: firmware = String(decoding: p.prefix(while: { $0 != 0 }), as: UTF8.self)
        case 16398:
            if let count = p.first, p.count >= 1 + Int(count) * 2 {
                for index in 0..<Int(count) {
                    let offset = 1 + index * 2
                    if p[offset] == 1, p[offset + 1] <= 1 { inEar = p[offset + 1] == 1 }
                }
            }
        case 16449: if let v = p.first, v == 1 || v == 2 { latency = v == 1 }
        case 16462: if p.count >= 2 { bass = p[0] == 1; bassWire = p[1] }
        case 16416: if let v = p.first { personalizedANC = v == 1 }
        case 16423: if let v = p.first { dual = v == 1 }
        case 16463:
            if let mode = p.first { spatial = p.count >= 2 && p[1] == 1 ? 1 : SpatialMode.all.first(where: { $0.head == 0 && $0.mode == mode })?.id }
        case 16460: if let v = p.first { advancedEQ = v == 1 }
        case 16488, 24604: if let v = p.first { flatEQ = v == 1 }
        case 16425: codec = p.first
        case 16487: if let v = p.first { longPower = v == 1 }
        case 16497: antiLeakage = p.first
        case 16418, 16474, 24601: if let v = p.first, v <= 1 { personalSound = v == 1 }
        case 24589: if p.count >= 2, let l = FitResult(rawValue: p[0]), let r = FitResult(rawValue: p[1]) { fitLeft = l; fitRight = r }
        case 16424:
            if let page = DualDevice.page(p) {
                for device in page {
                    if let index = dualDevices.firstIndex(where: { $0.id == device.id }) { dualDevices[index] = device }
                    else { dualDevices.append(device) }
                }
            }
        case 24590:
            if p.count >= 7, let index = dualDevices.firstIndex(where: { $0.address == Array(p[1...6]) }) { dualDevices[index].connected = p[0] == 1 }
        case 16397: if p.count >= 2 { dualListSupported = p[1] & 0x40 != 0 }
        case 16482: if let v = p.first, v <= 1 { exclusion = v == 1 }
        default: break
        }
    }
}
public enum Encoder {
    public static func uint16(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)] }
    public static func inEar(_ enabled: Bool) -> [UInt8] { [1, 1, enabled ? 1 : 0] }
    public static func latency(_ enabled: Bool) -> [UInt8] { [enabled ? 1 : 2, 0] }
    public static func bass(_ enabled: Bool, level: Int, threeStage: Bool) -> [UInt8] {
        let safe = max(0, min(threeStage ? 2 : 5, level))
        return [enabled ? 1 : 0, UInt8(threeStage ? [0, 5, 10][safe] : safe * 2)]
    }
    public static func ring(base: String, enabled: Bool, left: Bool) -> [UInt8] {
        if ModelRules.includes("legacyRing", base) { return [enabled ? 1 : 0] }
        if ModelRules.includes("stereoRing", base) { return [6, enabled ? 1 : 0] }
        return [left ? 2 : 3, enabled ? 1 : 0]
    }
    public static func utc(seconds: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: seconds), UInt8(truncatingIfNeeded: seconds >> 8), UInt8(truncatingIfNeeded: seconds >> 16), UInt8(truncatingIfNeeded: seconds >> 24)]
    }
}
