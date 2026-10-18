import Foundation
import Testing
import DeviceProtocol

private func hex(_ value: String) -> [UInt8] {
    stride(from: 0, to: value.count, by: 2).map { offset in
        let start = value.index(value.startIndex, offsetBy: offset)
        return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
    }
}
// Frozen vectors from createEQPacket / buildAdvancedEQBandsPacket in
// res/js/bluetooth_socket.js, executed with Bun. APK SimpleEQEntity omits
// JS's final 9 padding bytes; advanced selector follows APK's u16 width.
@Test func equalizerPacketsMatchJSAndAPK() throws {
    let padded = hex("03000040c001000080bf000075443333333f020000404000c05a450000803f000000004000000c43cdcc4c3f000000000000000000")
    let custom = try #require(EqualizerProfile.decode(padded, advanced: false))
    #expect(custom.totalGain == -3)
    #expect(custom.bands.map(\.filter) == [1, 2, 0])
    #expect(custom.bands.map(\.gain) == [-1, 3, 2])
    #expect(custom.bands.map(\.frequency) == [980, 3500, 140])
    #expect(custom.encoded(advanced: false) == Array(padded.dropLast(9)))
    #expect(EqualizerProfile.decode(custom.encoded(advanced: false), advanced: false) == custom)
    let bytes = hex("00080000c0c001000080bf00005c420000803f01000000000000dc420000803f010000803f00005c430000803f01000080bf0000dc430000803f01000000000000a5440000803f010000803f00404e450000803f01000080bf0040ce450000803f010000000000404e460000803f")
    let advanced = try #require(EqualizerProfile.decode(bytes, advanced: true))
    #expect(advanced.totalGain == -6 && advanced.bands.count == 8)
    #expect(advanced.bands.map(\.frequency) == EqualizerProfile.frequencies)
    #expect(advanced.encoded(advanced: true) == bytes)
    #expect(Command.readPayload(Command.advancedBands) == [255, 0])
    #expect(Packet(Command.setCustomEQ, custom.encoded(advanced: false)).command == 0xf041)
    #expect(Packet(Command.setAdvancedBands, bytes).command == 0xf050)
}

@Test func equalizerPreservesMetadataAndRejectsMalformedReplies() throws {
    var profile = EqualizerProfile.flatAdvanced
    profile.profile = 7; profile.totalGain = -4.5
    profile.bands[0] = .init(filter: 2, gain: 2.5, frequency: 77, quality: 0.7)
    #expect(EqualizerProfile.decode(profile.encoded(advanced: true), advanced: true) == profile)
    let bytes = profile.encoded(advanced: true)
    for length in 0..<bytes.count { #expect(EqualizerProfile.decode(Array(bytes.prefix(length)), advanced: true) == nil) }
    #expect(EqualizerProfile.decode(bytes + [1], advanced: true) == nil)
    profile.bands[0].gain = .nan
    #expect(EqualizerProfile.decode(profile.encoded(advanced: true), advanced: true) == nil)
    profile.bands[0].gain = 99
    #expect(!profile.validated(advanced: true))
    var state = Demo.state(base: "B170")
    let previous = state.advancedBands
    state.apply(Frame(command: 16461, payload: [0, 8]))
    #expect(state.advancedBands == previous)
}

@Test func equalizerReducerConfirmsAndRollsBackOnlyBands() throws {
    for base in ["B170", "B171"] {
        let catalog = try ModelCatalog()
        let model = try #require(catalog.model(id: base == "B170" ? "C19ECD" : "FEB1C7"))
        var state = Demo.state(base: base)
        let c = Capabilities(model: model, config: try #require(catalog.config(base: base, firmware: state.firmware)), firmware: state.firmware)
        let initial = try #require(state.customEQ)
        #expect(initial.bands.map(\.frequency) == [980, base == "B170" ? 3500 : 3400, 140])
        #expect(initial.bands.map(\.quality) == [0.7, 1, 0.8])
        state.eq = 5
        var next = initial; next.bands[2].gain = 2; next.totalGain = -2
        let edit = try DeviceAction.customEQ(next).prepare(capabilities: c, state: state)
        #expect(edit.reads == [Command.customEQ])
        #expect(!edit.isConfirmed(by: state))
        edit.apply(to: &state)
        #expect(edit.isConfirmed(by: state))
        state.batteries[.stereo] = .init(percent: 71, charging: true)
        edit.rollback(&state)
        #expect(state.customEQ == initial && state.batteries[.stereo]?.percent == 71)
        state.advancedEQ = true
        var advanced = try #require(state.advancedBands); advanced.bands[3].gain = -2.5
        let advancedEdit = try DeviceAction.advancedBands(advanced).prepare(capabilities: c, state: state)
        #expect(advancedEdit.reads == [Command.advancedBands])
        advancedEdit.apply(to: &state)
        #expect(advancedEdit.isConfirmed(by: state))
        state.advancedBands?.bands[0].gain = 1
        #expect(!advancedEdit.isConfirmed(by: state))
        if base == "B170" {
            state.spatial = 1
            #expect(throws: ControlFailure.self) { try DeviceAction.advancedBands(advanced).prepare(capabilities: c, state: state) }
        }
    }
}
