import Foundation

public struct AudioDeviceModel: Codable, Equatable, Sendable {
    public let name: String
    public let base: String
    public let altBase: String?
    public var singleBattery: Bool { ModelRules.includes("singleBattery", base) }
}
public struct FirmwareConfig: Decodable, Sendable {
    public let customEQ: CustomEQParameters?
    public let minFirmware: String?, maxFirmware: String?
    public let ancLevel: Int?, earDetection: Int?, lowLagMode: Int?, ultraBass: Int?, ultraBassType: Int?
    public let dualConnection: Int?, dualConnectionReboot: Int?, personalizedAnc: Int?, advancedEq: Int?
    public let spatialAudio: Int?, useAudiodoSpatial: Int?, mutuallyExclusive: Int?, supportStudio: Int?
    public let diracOpteoSupport: Int?
    public let longPowerMode: Int?, supportLeakageProtection: Int?, highQualityAudio: Int?, spatialLdacExclusive: Int?
    public let mimi: Int?, audiodo: Int?, earTipFitTest: Int?, findDevice: Int?
}
private struct ModelConfigs: Decodable, Sendable { let id: String; let configs: [FirmwareConfig] }

public struct ModelCatalog: Sendable {
    public let models: [String: AudioDeviceModel]
    private let configs: [ModelConfigs]
    public init() throws {
        _ = try ModelRules.loaded.get()
        guard let modelsURL = ProtocolResources.bundle.url(forResource: "models", withExtension: "json"),
              let configsURL = ProtocolResources.bundle.url(forResource: "ear_config_file", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        models = try JSONDecoder().decode([String: AudioDeviceModel].self, from: Data(contentsOf: modelsURL))
        configs = try JSONDecoder().decode([ModelConfigs].self, from: Data(contentsOf: configsURL))
    }
    public func model(id: String) -> AudioDeviceModel? { models[id.uppercased()] }
    /// Fallback identification by the Bluetooth device name, for devices that do not
    /// expose (or never answer on) the Fast Pair RFCOMM service. Exact names win; otherwise
    /// the longest catalog name contained in the device name (handles "Nothing Ear" vs
    /// "Nothing Ear (a)" correctly).
    public func model(named deviceName: String) -> AudioDeviceModel? {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let sorted = models.sorted { $0.key < $1.key }.map(\.value)
        if let exact = sorted.first(where: { $0.name.lowercased() == name }) { return exact }
        return sorted.filter { name.contains($0.name.lowercased()) }.max { $0.name.count < $1.name.count }
    }
    public func config(base: String, firmware: String) -> FirmwareConfig? {
        guard let list = configs.first(where: { $0.id == base })?.configs else { return nil }
        if list.count == 1 { return list.first }
        guard !firmware.isEmpty else { return nil }
        return list.first { VersionRange.contains(firmware, min: $0.minFirmware, max: $0.maxFirmware) }
    }
}
public enum VersionRange {
    public static func compare(_ lhs: String, _ rhs: String) -> Int? {
        guard !lhs.isEmpty, !rhs.isEmpty else { return nil }
        guard let left = lhs.split(separator: "-", maxSplits: 1).first,
              let right = rhs.split(separator: "-", maxSplits: 1).first else { return nil }
        let a = left.split(separator: ".").map(String.init)
        let b = right.split(separator: ".").map(String.init)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0", y = i < b.count ? b[i] : "0"
            if x == "*" || y == "*" { continue }
            guard let n = Int(x), let m = Int(y) else { return nil }
            if n != m { return n < m ? -1 : 1 }
        }
        return 0
    }
    public static func contains(_ value: String, min: String?, max: String?) -> Bool {
        guard !value.isEmpty else { return false }
        if let min, !min.isEmpty { guard let c = compare(value, min), c >= 0 else { return false } }
        if let max, !max.isEmpty { guard let c = compare(value, max), c <= 0 else { return false } }
        return true
    }
}
/// Fast Pair pushes a seven-byte record. Buffering is independent of RFCOMM read boundaries.
public struct FastPairDecoder: Sendable {
    private var bytes: [UInt8] = []
    public init() {}
    public mutating func append(_ incoming: [UInt8]) -> String? {
        guard bytes.count < 7 else { return nil }
        bytes.append(contentsOf: incoming.prefix(7 - bytes.count))
        guard bytes.count == 7 else { return nil }
        return bytes[4...6].map { String(format: "%02X", $0) }.joined()
    }
}
public struct Capabilities: Sendable {
    public let model: AudioDeviceModel, config: FirmwareConfig, firmware: String
    public init(model: AudioDeviceModel, config: FirmwareConfig, firmware: String) {
        self.model = model; self.config = config; self.firmware = firmware
    }
    public var listeningMode: Bool { ModelRules.includes("listeningMode", model.base) }
    public var anc: Bool {
        if ModelRules.includes("firmwareANC", model.base) { return firmware.split(separator: ".").dropFirst(2).first == "2" }
        return (config.ancLevel ?? 0) != 0
    }
    public var ancModes: [ANCMode] {
        guard anc else { return [] }
        let mask = config.ancLevel ?? 0
        var modes: [ANCMode] = [.off]
        if mask & 0x10 != 0 { modes.append(.transparency) }
        modes.append(.high) // ANC on always uses wire 1, even without a strength selector.
        if mask & 4 != 0 {
            if mask & 2 != 0 { modes.append(.medium) }
            modes.append(.low)
        }
        if mask & 8 != 0 { modes.append(.adaptive) }
        return modes
    }
    public var inEar: Bool { config.earDetection != 0 && !ModelRules.includes("noWearDetection", model.base) }
    public var latency: Bool { config.lowLagMode != 0 }
    public var bassReadable: Bool { config.ultraBass == 1 }
    public var bassWritable: Bool {
        bassReadable && ModelRules.includes("bassWritable", model.base)
    }
    public var threeStageBass: Bool { ModelRules.includes("threeStageBass", model.base) }
    public var personalizedANC: Bool { ModelRules.includes("personalizedANC", model.base) && config.personalizedAnc == 1 }
    public var dual: Bool { config.dualConnection == 1 }
    public var dualNeedsReboot: Bool { config.dualConnectionReboot == 1 }
    public var personalSoundRead: UInt16? { config.mimi == 1 ? Command.mimi : config.audiodo == 1 ? Command.audiodo : nil }
    public var personalSoundWrite: UInt16? { config.mimi == 1 ? Command.setMimi : config.audiodo == 1 ? Command.setAudiodo : nil }
    public var earFit: Bool { config.earTipFitTest == 1 && ModelRules.includes("earFit", model.base) }
    public var find: Bool { config.findDevice != 0 }
    public var codecChoices: [AudioChoice] {
        guard let mask = config.highQualityAudio, mask != 0 else { return [] }
        var result = [AudioChoice(0, "AAC")]
        if mask & 2 != 0 { result.append(.init(1, "LHDC")) }
        if mask & 4 != 0 { result.append(.init(2, "LDAC")) }
        return result
    }
    public var customEQ: Bool { config.customEQ != nil && model.base != "B181" && !listeningMode }
    public var advancedEQ: Bool { config.advancedEq == 1 }
    public var spatialModes: [SpatialMode] {
        guard config.useAudiodoSpatial != 1, let mask = config.spatialAudio, mask != 0 else { return [] }
        return SpatialMode.all.filter { $0.id == 0 || mask & $0.bit != 0 }
    }
    public var audioChoices: [AudioChoice] {
        if listeningMode {
            var choices = [AudioChoice(3, "Pop"), .init(1, "Rock"), .init(2, "Electronic"), .init(5, "Classical"), .init(4, "Enhance vocals")]
            if !ModelRules.includes("noDirac", model.base) { choices.insert(.init(ModelRules.includes("diracID7", model.base) ? 7 : 0, ModelRules.includes("diracID7", model.base) ? "Dirac" : "Dirac Opteo"), at: 0) }
            choices.append(.init(6, "Custom"))
            return choices
        }
        var choices = [AudioChoice(0, "Balanced"), .init(3, "More bass"), .init(2, "More treble"), .init(1, "More vocals")]
        if !ModelRules.includes("noCustomEQ", model.base) { choices.append(.init(5, "Custom")) }
        if advancedEQ { choices.append(.init(6, "Advanced")) }
        if ModelRules.includes("detailEQ", model.base) { choices.append(.init(7, "More detail")) }
        return choices
    }
    public func bassLevel(wire: UInt8) -> Int? {
        if threeStageBass { return [UInt8(0), 5, 10].firstIndex(of: wire) }
        return wire <= 10 && wire % 2 == 0 ? Int(wire / 2) : nil
    }
    public func audioBlock(_ state: DeviceState) -> String? {
        if config.supportStudio == 1 && state.flatEQ != false { return "Flat EQ is active or its status is unavailable. Use the switch on the left earcup." }
        if config.longPowerMode == 1 && state.longPower != false { return "Long battery life mode is active or its status is unavailable." }
        if config.supportLeakageProtection == 1 && (state.antiLeakage == nil || state.antiLeakage == 2) { return "Anti-leakage mode is active or its status is unavailable." }
        return nil
    }
    public func bassBlock(_ state: DeviceState) -> String? {
        if let reason = audioBlock(state) { return reason }
        if config.mutuallyExclusive == 1 && state.spatial != 0 { return "Turn off Spatial Audio before enabling Bass Enhance." }
        return nil
    }
    public func spatialBlock(_ state: DeviceState) -> String? {
        if let reason = audioBlock(state) { return reason }
        if config.mutuallyExclusive == 1 && (state.bass != false || state.advancedEQ != false) { return "Turn off Bass Enhance and Advanced EQ before enabling Spatial Audio." }
        if config.spatialLdacExclusive == 1 && (state.codec == nil || state.codec == 2) { return "Spatial Audio is unavailable while LDAC is active or its status is unknown." }
        return nil
    }
    public func choiceBlock(_ choice: UInt8, state: DeviceState) -> String? {
        if let reason = audioBlock(state) { return reason }
        if !listeningMode && choice == 6 && config.mutuallyExclusive == 1 && state.spatial != 0 { return "Turn off Spatial Audio before enabling Advanced EQ." }
        if !listeningMode && choice != 0 && choice != 5 && config.mutuallyExclusive == 1 && state.spatial != 0 && state.exclusion == true { return "This device reports that Spatial Audio blocks this EQ preset. Turn Spatial Audio off first." }
        if config.diracOpteoSupport == 1 && choice == 0 && (state.codec == nil || state.codec == 2) { return "Dirac Opteo is unavailable while LDAC is active or its status is unknown." }
        return nil
    }
}
