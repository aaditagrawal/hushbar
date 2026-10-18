import Foundation

public struct ControlFailure: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Packet: Equatable, Sendable {
    public let command: UInt16, payload: [UInt8]
    public init(_ command: UInt16, _ payload: [UInt8]) { self.command = command; self.payload = payload }
}
/// Pure reducer shared by live optimistic edits and the interactive demo.
public enum DeviceAction: Sendable {
    case customEQ(EqualizerProfile), advancedBands(EqualizerProfile)
    case anc(ANCMode), eq(UInt8), inEar(Bool), latency(Bool), bass(Bool, Int?)
    case personalized(Bool), dual(Bool), spatial(Int), codec(UInt8), personalSound(Bool)
    public var key: String {
        switch self {
        case .customEQ, .advancedBands: "eqBands"
        case .anc: "anc"; case .eq: "eq"; case .inEar: "inEar"; case .latency: "latency"
        case .bass: "bass"; case .personalized: "personalized"; case .dual: "dual"
        case .spatial: "spatial"; case .codec: "codec"; case .personalSound: "personalSound"
        }
    }
    public func prepare(capabilities c: Capabilities, state s: DeviceState) throws -> DeviceEdit {
        var next = s
        var packets: [Packet] = [], reads: [UInt16] = []
        var reboot = false
        func require(_ allowed: Bool, _ reason: String = "This control is unavailable on this device.") throws {
            if !allowed { throw ControlFailure(message: reason) }
        }
        func unblock(_ reason: String?) throws { if let reason { throw ControlFailure(message: reason) } }
        switch self {
        case .customEQ(let profile):
            try require(c.customEQ && s.eq == 5 && s.advancedEQ != true && s.customEQ != nil)
            try require(profile.validated(advanced: false)); try unblock(c.choiceBlock(5, state: s))
            next.customEQ = profile; packets = [.init(Command.setCustomEQ, profile.encoded(advanced: false))]; reads = [Command.customEQ]
        case .advancedBands(let profile):
            try require(c.advancedEQ && s.advancedEQ == true && s.advancedBands != nil)
            try require(profile.validated(advanced: true)); try unblock(c.choiceBlock(6, state: s))
            next.advancedBands = profile; packets = [.init(Command.setAdvancedBands, profile.encoded(advanced: true))]; reads = [Command.advancedBands]
        case .anc(let mode):
            try require(c.ancModes.contains(mode))
            if mode == .transparency { try unblock(c.audioBlock(s)) }
            next.anc = mode; packets = [.init(Command.setANC, mode.payload)]; reads = [Command.anc]
        case .eq(let value):
            try require(c.audioChoices.contains { $0.id == value }); try unblock(c.choiceBlock(value, state: s))
            let advanced = !c.listeningMode && value == 6
            next.advancedEQ = advanced
            if c.advancedEQ { packets.append(.init(Command.setAdvancedEQ, [advanced ? 1 : 0, 0])) }
            if !advanced {
                next.eq = value
                packets.append(.init(c.listeningMode ? Command.setListeningMode : Command.setEQ, [value, 0]))
                reads.append(c.listeningMode ? Command.listeningMode : Command.eq)
            }
            if c.advancedEQ { reads.append(Command.advancedEQ) }
        case .inEar(let enabled):
            try require(c.inEar); next.inEar = enabled
            packets = [.init(Command.setInEar, Encoder.inEar(enabled))]; reads = [Command.inEar]
        case .latency(let enabled):
            try require(c.latency); next.latency = enabled
            packets = [.init(Command.setLatency, Encoder.latency(enabled))]; reads = [Command.latency]
        case .bass(let enabled, let level):
            try require(c.bassWritable)
            let active = c.threeStageBass && level != nil ? level != 0 : enabled
            if active { try unblock(c.bassBlock(s)) }
            let payload = Encoder.bass(active, level: level ?? c.bassLevel(wire: s.bassWire) ?? (c.threeStageBass ? 1 : 3), threeStage: c.threeStageBass)
            next.bass = active; next.bassWire = payload[1]
            packets = [.init(Command.setBass, payload)]; reads = [Command.bass]
        case .personalized(let enabled):
            try require(c.personalizedANC); next.personalizedANC = enabled
            packets = [.init(Command.setPersonalizedANC, [enabled ? 1 : 0])]; reads = [Command.personalizedANC]
        case .dual(let enabled):
            try require(c.dual); next.dual = enabled; reboot = c.dualNeedsReboot
            packets = [.init(Command.setDual, [enabled ? 1 : 0])]; reads = [Command.dual]
        case .spatial(let id):
            let mode = c.spatialModes.first { $0.id == id }
            try require(mode != nil)
            if id != 0 { try unblock(c.spatialBlock(s)) }
            if let mode { next.spatial = id; packets = [.init(Command.setSpatial, mode.payload)]; reads = [Command.spatial] }
        case .codec(let value):
            try require(c.codecChoices.contains { $0.id == value })
            try require(c.config.longPowerMode != 1 || s.longPower == false, "Turn off Long Battery Life Mode first.")
            next.codec = value; reboot = true
            packets = [.init(Command.setCodec, [value, 0])]; reads = [Command.codec]
        case .personalSound(let enabled):
            guard let read = c.personalSoundRead, let write = c.personalSoundWrite else { throw ControlFailure(message: "No saved sound profile is supported.") }
            try require(!enabled || c.config.mimi != 1 || (s.codec != nil && s.codec != 2), "Personal Sound Profile is unavailable while LDAC is active or its status is unknown.")
            next.personalSound = enabled; packets = [.init(write, c.config.mimi == 1 ? [enabled ? 1 : 0, 0] : [enabled ? 1 : 0])]; reads = [read]
        }
        return DeviceEdit(action: self, before: s, after: next, packets: packets, reads: reads, reboot: reboot)
    }
    fileprivate func copyFields(from source: DeviceState, into target: inout DeviceState) {
        switch self {
        case .customEQ: target.customEQ = source.customEQ
        case .advancedBands: target.advancedBands = source.advancedBands
        case .anc: target.anc = source.anc
        case .eq: target.eq = source.eq; target.advancedEQ = source.advancedEQ
        case .inEar: target.inEar = source.inEar
        case .latency: target.latency = source.latency
        case .bass: target.bass = source.bass; target.bassWire = source.bassWire
        case .personalized: target.personalizedANC = source.personalizedANC
        case .dual: target.dual = source.dual
        case .spatial: target.spatial = source.spatial
        case .codec: target.codec = source.codec
        case .personalSound: target.personalSound = source.personalSound
        }
    }
}
public struct DeviceEdit: Sendable {
    public let action: DeviceAction, before: DeviceState, after: DeviceState
    public let packets: [Packet], reads: [UInt16], reboot: Bool
    public func apply(to state: inout DeviceState) { action.copyFields(from: after, into: &state) }
    public func rollback(_ state: inout DeviceState) { action.copyFields(from: before, into: &state) }
    public func isConfirmed(by state: DeviceState) -> Bool {
        switch action {
        case .customEQ(let profile): return profile.matches(state.customEQ)
        case .advancedBands(let profile): return profile.matches(state.advancedBands)
        default: break
        }
        var expected = state
        action.copyFields(from: after, into: &expected)
        return expected == state
    }
}

public enum Demo {
    public static func requestedBase(environment: [String: String], arguments: [String]) -> String? {
        let value = environment["HUSHBAR_DEMO"]?.uppercased()
        if value == "B170" || arguments.contains("--demo=B170") { return "B170" }
        if value == "B171" || value == "1" || arguments.contains("--demo") || arguments.contains("--demo=B171") {
            return environment["HUSHBAR_DEMO_MODEL"] == "B170" ? "B170" : "B171"
        }
        return nil
    }
    public static func state(base: String) -> DeviceState {
        var s = DeviceState()
        s.firmware = base == "B170" ? "1.0.1.75" : "1.0.1.50"
        s.customEQ = (try? ModelCatalog())?.config(base: base, firmware: s.firmware)?.customEQ?.flat
        s.advancedBands = .flatAdvanced
        s.anc = .high; s.eq = 0; s.inEar = true; s.latency = false
        s.bass = false; s.bassWire = 6; s.dual = true; s.codec = 0
        s.advancedEQ = false; s.spatial = 0; s.personalSound = false; s.dualListSupported = true; s.exclusion = false
        s.batteries = base == "B170" ? [.stereo: .init(percent: 82, charging: false)] : [.left: .init(percent: 86, charging: false), .right: .init(percent: 82, charging: false), .chargingCase: .init(percent: 64, charging: true)]
        s.dualDevices = [.init(address: [1, 2, 3, 4, 5, 6], name: "This Mac", isSelf: true, connected: true), .init(address: [6, 5, 4, 3, 2, 1], name: "Nothing Phone", isSelf: false, connected: false)]
        return s
    }
}
