import Testing
import DeviceProtocol

private func catalog() throws -> ModelCatalog { try ModelCatalog() }
private func caps(_ id: String, firmware: String = "1.0.1.100") throws -> Capabilities {
    let table = try catalog()
    let model = try #require(table.model(id: id))
    return Capabilities(model: model, config: try #require(table.config(base: model.base, firmware: firmware)), firmware: firmware)
}

@Test func crcStandardVector() { #expect(CRC16.modbus(Array("123456789".utf8)) == 0x4b37) }
@Test func crcEmptyVector() { #expect(CRC16.modbus([UInt8]()) == 0xffff) }
// Byte-for-byte output of bluetooth_socket.js send(49159, []) with operationID = 1.
@Test func batteryRequestMatchesJavaScript() {
    #expect(Frame(command: Command.battery, operation: 1).encoded == [0x55, 0x60, 1, 7, 0xc0, 0, 0, 1, 0xac, 0xdf])
}
@Test func ancRequestMatchesJavaScript() {
    #expect(Frame(command: Command.setANC, operation: 1, payload: ANCMode.adaptive.payload).encoded == [0x55, 0x60, 1, 0x0f, 0xf0, 3, 0, 1, 1, 4, 0, 0xfa, 0x87])
}
@Test func bassRequestMatchesJavaScript() {
    #expect(Frame(command: Command.setBass, operation: 1, payload: [1, 6]).encoded == [0x55, 0x60, 1, 0x51, 0xf0, 2, 0, 1, 1, 6, 0xf7, 0x3f])
}
@Test func everyPossibleSplit() {
    let frame = Frame(command: 16391, operation: 17, payload: [3, 2, 86, 3, 82, 4, 192])
    for split in 0...frame.encoded.count {
        var decoder = FrameDecoder()
        let first = decoder.append(Array(frame.encoded.prefix(split)))
        let second = decoder.append(Array(frame.encoded.dropFirst(split)))
        #expect(first + second == [frame])
    }
}
@Test func coalescedFramesAndBytewiseReads() {
    let frames = [Frame(command: 16391, payload: [1, 6, 82]), Frame(command: 16414, payload: [1, 4]), Frame(command: 16415, payload: [3])]
    var decoder = FrameDecoder()
    #expect(decoder.append(frames.flatMap(\.encoded)) == frames)
    decoder.reset()
    var output: [Frame] = []
    for byte in frames.flatMap(\.encoded) { output += decoder.append([byte]) }
    #expect(output == frames)
}
@Test func noiseAndCRCRecovery() {
    let frame = Frame(command: 16415, payload: [3])
    var broken = frame.encoded; broken[8] ^= 1
    var decoder = FrameDecoder()
    #expect(decoder.append([0, 0x55, 0x60, 9, 77] + broken + frame.encoded) == [frame])
    #expect(decoder.rejectedPackets == 1)
}
@Test func badLengthAndLargeGarbageAreBounded() {
    var decoder = FrameDecoder(maximumPayload: 255)
    let frame = Frame(command: 16391)
    #expect(decoder.append(Array(repeating: 0, count: 100_000) + [0x55, 0x60, 1, 0, 0, 0, 1, 0] + frame.encoded) == [frame])
    #expect(decoder.rejectedPackets >= 1)
}
@Test func payloadMayContainHeaderBytes() {
    let f = Frame(command: 16450, payload: [0x55, 0x60, 1, 0, 255])
    var decoder = FrameDecoder()
    #expect(decoder.append(f.encoded) == [f])
}
@Test func maximumPayload() {
    let f = Frame(command: 16450, payload: Array(repeating: 99, count: 255))
    var decoder = FrameDecoder()
    #expect(decoder.append(f.encoded) == [f])
}
@Test func batteryCountsAndCharging() {
    var state = DeviceState()
    state.apply(Frame(command: 57345, payload: [3, 2, 86, 3, 82, 4, 0xc0]))
    #expect(state.batteries[.left] == Battery(percent: 86, charging: false))
    #expect(state.batteries[.chargingCase] == Battery(percent: 64, charging: true))
    #expect(state.lowestBattery == 64)
    state.apply(Frame(command: 16391, payload: [1, 6, 0xd2]))
    #expect(state.batteries.count == 1)
    #expect(state.batteries[.stereo] == Battery(percent: 82, charging: true))
}
@Test func malformedBatteryDoesNotClobberState() {
    var state = DeviceState()
    state.apply(Frame(command: 16391, payload: [1, 2, 82]))
    state.apply(Frame(command: 16391, payload: [3, 2]))
    #expect(state.batteries[.left]?.percent == 82)
    state.apply(Frame(command: 16391, payload: [2, 99, 12, 3, 127]))
    #expect(state.batteries.isEmpty)
}
@Test(arguments: ANCMode.allCases) func ancWireRoundTrip(_ mode: ANCMode) {
    var state = DeviceState()
    state.apply(Frame(command: 16414, payload: Array(mode.payload.prefix(2))))
    #expect(state.anc == mode)
}
@Test func ancLegacyWireMapping() {
    #expect([ANCMode.off, .transparency, .low, .high, .medium, .adaptive].map(\.rawValue) == [5, 7, 3, 1, 2, 4])
    var state = DeviceState()
    state.apply(Frame(command: 24579, payload: [1, 7]))
    #expect(state.anc == .transparency)
    state.apply(Frame(command: 57347, payload: [1, 2]))
    #expect(state.anc == .medium)
}
@Test func eqListeningAndFirmwareParsers() {
    var state = DeviceState()
    state.apply(Frame(command: 16415, payload: [3, 0]))
    #expect(state.eq == 3)
    state.apply(Frame(command: 16464, payload: [5]))
    #expect(state.eq == 5)
    state.apply(Frame(command: 16450, payload: Array("1.0.1.75".utf8) + [0]))
    #expect(state.firmware == "1.0.1.75")
}
@Test func toggleAndBassParsers() {
    var state = DeviceState()
    state.apply(Frame(command: 16398, payload: [1, 1, 1]))
    state.apply(Frame(command: 16449, payload: [2]))
    state.apply(Frame(command: 16462, payload: [1, 10]))
    #expect(state.inEar == true); #expect(state.latency == false)
    #expect(state.bass == true); #expect(state.bassWire == 10)
    #expect(Encoder.inEar(true) == [1, 1, 1]); #expect(Encoder.latency(false) == [2, 0])
}
@Test func shortPacketsNeverCrash() {
    for command: UInt16 in [16391, 16414, 16415, 16464, 16450, 16398, 16449, 16462, 16416, 16423, 16463, 16460, 16488, 16425, 16487, 16497] {
        for count in 0...3 { var state = DeviceState(); state.apply(Frame(command: command, payload: Array(repeating: 255, count: count))) }
    }
}
@Test func fastPairSplitAndModelLookup() throws {
    var decoder = FastPairDecoder()
    #expect(decoder.append([3, 0, 0]) == nil)
    #expect(decoder.append([0, 0xfe, 0xb1, 0xc7, 99]) == "FEB1C7")
    #expect(try catalog().model(id: "feb1c7")?.base == "B171")
    #expect(try catalog().model(id: "C19ECD")?.base == "B170")
    #expect(try catalog().model(id: "000000") == nil)
    #expect(try catalog().models.count == 74)
}
@Test func alternateBaseKeepsWebRouting() throws {
    let m = try #require(try catalog().model(id: "97EF75"))
    #expect(m.base == "B186"); #expect(m.altBase == "B198")
}
@Test func wildcardFirmwareBoundaries() throws {
    let table = try catalog()
    #expect(table.config(base: "B181", firmware: "0.0.1.74")?.lowLagMode == 0)
    #expect(table.config(base: "B181", firmware: "0.0.1.75")?.lowLagMode == nil)
    #expect(table.config(base: "B155", firmware: "1.0.1.94")?.advancedEq == 0)
    #expect(table.config(base: "B155", firmware: "1.0.1.95")?.advancedEq == 1)
    #expect(table.config(base: "B181", firmware: "") == nil)
    #expect(table.config(base: "UNKNOWN", firmware: "1.0.1") == nil)
    #expect(VersionRange.compare("1.0.1.75-beta", "*.*.1.75") == 0)
    #expect(VersionRange.compare("", "1") == nil)
}
@Test func earB171PriorityGates() throws {
    let c = try caps("FEB1C7")
    #expect(c.ancModes == [.off, .transparency, .high, .medium, .low, .adaptive])
    #expect(c.inEar && c.latency && c.bassWritable && c.dual && c.advancedEQ)
    #expect(!c.listeningMode && !c.personalizedANC && !c.threeStageBass)
    #expect(c.spatialModes.isEmpty)
    #expect(c.codecChoices.map(\.id) == [0, 1, 2])
    #expect(c.audioChoices.map(\.id) == [0, 3, 2, 1, 5, 6])
}
@Test func headphoneB170PriorityGates() throws {
    let c = try caps("C19ECD", firmware: "1.0.1.75")
    #expect(c.model.singleBattery)
    #expect(c.ancModes == [.off, .transparency, .high, .medium, .low, .adaptive])
    #expect(c.inEar && c.latency && c.bassWritable && c.dual && c.advancedEQ)
    #expect(!c.listeningMode && !c.personalizedANC)
    #expect(c.spatialModes.map(\.id) == [0, 1, 2])
    #expect(c.codecChoices.map(\.id) == [0, 2])
    #expect(c.config.mutuallyExclusive == 1)
    #expect(!c.dualNeedsReboot)
}
@Test func stickFirmwareGate() throws {
    #expect(try caps("1016DD", firmware: "1.0.1.90").anc == false)
    #expect(try caps("1016DD", firmware: "1.0.2.0").ancModes == [.off, .high])
}
@Test func noANCAndNoWearDetection() throws {
    let c = try caps("FC3AAF")
    #expect(!c.anc && !c.inEar && !c.bassReadable)
    #expect(try caps("4DFC4A").inEar == false)
}
@Test func basicANCMask() throws {
    #expect(try caps("D35E18").ancModes == [.off, .transparency, .high])
    #expect(try caps("5F8F82").ancModes == [.off, .transparency, .high, .medium, .low])
}
@Test func everyModelHasMatchingConfig() throws {
    let table = try catalog()
    for model in table.models.values {
        #expect(table.config(base: model.base, firmware: "1.0.1.100") != nil)
    }
}
@Test func bassEncodingAndThreeStageRoundTrip() throws {
    for id in ["8F28ED", "BFD53B", "A544CE", "3B1320"] {
        let c = try caps(id)
        #expect(c.threeStageBass)
        for level in 0...2 {
            let bytes = Encoder.bass(true, level: level, threeStage: true)
            #expect(bytes == [1, UInt8([0, 5, 10][level])])
            #expect(c.bassLevel(wire: bytes[1]) == level)
        }
    }
    #expect(Encoder.bass(true, level: 3, threeStage: false) == [1, 6])
    #expect(Encoder.bass(false, level: 99, threeStage: true) == [0, 10])
}
@Test func listeningModeAndB185ReadOnly() throws {
    let table = try catalog()
    let bases: Set<String> = ["B172", "B195", "B168", "B179", "B197", "B184", "B185", "B175", "B189"]
    for (id, model) in table.models {
        let c = try caps(id)
        #expect(c.listeningMode == bases.contains(model.base))
        if model.base == "B185" { #expect(c.bassReadable && !c.bassWritable); #expect(c.audioChoices.first?.id == 7) }
        if model.base == "B175" { #expect(c.audioChoices.allSatisfy { $0.id != 0 }) }
    }
}
@Test func spatialAndBassExclusions() throws {
    let c = try caps("C19ECD")
    var state = DeviceState(); state.spatial = 1; state.bass = false; state.advancedEQ = false
    #expect(c.bassBlock(state) != nil)
    state.spatial = 0
    #expect(c.bassBlock(state) == nil)
    state.bass = true
    #expect(c.spatialBlock(state) != nil)
    state.bass = false; state.advancedEQ = true
    #expect(c.spatialBlock(state) != nil)
    state.advancedEQ = false
    #expect(c.spatialBlock(state) == nil)
}
@Test func spatialWireParser() {
    var s = DeviceState()
    s.apply(Frame(command: 16463, payload: [1, 1])); #expect(s.spatial == 1)
    s.apply(Frame(command: 16463, payload: [1, 0])); #expect(s.spatial == 2)
    s.apply(Frame(command: 16463, payload: [3, 0])); #expect(s.spatial == 4)
    #expect(SpatialMode.all[1].payload == [1, 1])
}
@Test func studioAndAudiodoGate() throws {
    let c = try caps("CDFDEC")
    #expect(c.spatialModes.isEmpty)
    #expect(c.audioChoices.last?.id == 7)
    var s = DeviceState()
    #expect(c.audioBlock(s) != nil)
    s.flatEQ = false; #expect(c.audioBlock(s) == nil)
    s.flatEQ = true; #expect(c.audioBlock(s) != nil)
}
@Test func ringEncodersAndTime() {
    #expect(Encoder.ring(base: "B171", enabled: true, left: true) == [2, 1])
    #expect(Encoder.ring(base: "B171", enabled: false, left: false) == [3, 0])
    #expect(Encoder.ring(base: "B170", enabled: true, left: true) == [6, 1])
    #expect(Encoder.ring(base: "B181", enabled: false, left: true) == [0])
    #expect(Encoder.utc(seconds: 0x12345678) == [0x78, 0x56, 0x34, 0x12])
}
@Test func ldacAndSavedProfileGates() throws {
    let c = try caps("F29566")
    var s = DeviceState(); s.codec = 2
    #expect(c.choiceBlock(0, state: s) != nil)
    #expect(c.choiceBlock(3, state: s) == nil)
    s.codec = 0
    #expect(c.choiceBlock(0, state: s) == nil)
    let h = try caps("C19ECD")
    s.spatial = 1
    #expect(h.choiceBlock(6, state: s) != nil)
    #expect(h.choiceBlock(3, state: s) == nil)
    #expect(try caps("31D53D").audioChoices.count == 4)
}
@Test func personalizedOnlyEarTwo() throws {
    #expect(try caps("ACC520").personalizedANC)
    #expect(try caps("FEB1C7").personalizedANC == false)
    #expect(try caps("C19ECD").personalizedANC == false)
}

@Test func allPriorityFastPairVariants() throws {
    let table = try catalog()
    for id in ["FEB1C7", "A20444"] { #expect(table.model(id: id)?.base == "B171") }
    for id in ["C19ECD", "2D6FDA"] { #expect(table.model(id: id)?.base == "B170") }
    #expect(table.models.filter { ["B171", "B170"].contains($0.value.base) }.count == 4)
}
@Test func savedHearingProfileFirmwareGates() throws {
    let ear = try caps("FEB1C7")
    #expect(ear.personalSoundRead == Command.mimi && ear.personalSoundWrite == Command.setMimi)
    #expect(ear.earFit && ear.find)
    let old = try caps("C19ECD", firmware: "1.0.1.74")
    let current = try caps("C19ECD", firmware: "1.0.1.75")
    #expect(old.personalSoundRead == nil && !old.earFit)
    #expect(current.personalSoundRead == Command.audiodo && current.personalSoundWrite == Command.setAudiodo)
    #expect(!current.earFit && current.find)
}
@Test func demoLaunchSelectors() {
    #expect(Demo.requestedBase(environment: [:], arguments: []) == nil)
    #expect(Demo.requestedBase(environment: ["HUSHBAR_DEMO": "1"], arguments: []) == "B171")
    #expect(Demo.requestedBase(environment: ["HUSHBAR_DEMO": "B170"], arguments: []) == "B170")
    #expect(Demo.requestedBase(environment: ["HUSHBAR_DEMO": "B171"], arguments: []) == "B171")
    #expect(Demo.requestedBase(environment: [:], arguments: ["--demo"]) == "B171")
    #expect(Demo.requestedBase(environment: [:], arguments: ["--demo=B170"]) == "B170")
    #expect(Demo.requestedBase(environment: ["HUSHBAR_DEMO": "0"], arguments: []) == nil)
}
@Test func reducerPlansMatchJavaScriptAndAPK() throws {
    let c = try caps("FEB1C7")
    let s = Demo.state(base: "B171")
    let cases: [(DeviceAction, [Packet], [UInt16])] = [
        (.anc(.medium), [.init(61455, [1, 2, 0])], [49182]),
        (.eq(3), [.init(61519, [0, 0]), .init(61456, [3, 0])], [49183, 49228]),
        (.eq(6), [.init(61519, [1, 0])], [49228]),
        (.inEar(false), [.init(61444, [1, 1, 0])], [49166]),
        (.latency(false), [.init(61504, [2, 0])], [49217]),
        (.bass(true, 3), [.init(61521, [1, 6])], [49230]),
        (.dual(false), [.init(61466, [0])], [49191]),
        (.codec(2), [.init(61468, [2, 0])], [49193]),
        (.personalSound(true), [.init(61461, [1, 0])], [49186])
    ]
    for (action, packets, reads) in cases {
        let edit = try action.prepare(capabilities: c, state: s)
        #expect(edit.packets == packets && edit.reads == reads)
        var reduced = s; edit.apply(to: &reduced)
        #expect(edit.isConfirmed(by: reduced))
        edit.rollback(&reduced); #expect(reduced == s)
    }
}
@Test func rollbackPreservesPushUpdates() throws {
    let c = try caps("FEB1C7")
    var s = Demo.state(base: "B171")
    let edit = try DeviceAction.eq(6).prepare(capabilities: c, state: s)
    edit.apply(to: &s)
    s.apply(Frame(command: 16391, payload: [1, 2, 42]))
    s.anc = .low
    edit.rollback(&s)
    #expect(s.eq == 0 && s.advancedEQ == false)
    #expect(s.anc == .low && s.batteries[.left]?.percent == 42)
    #expect(!edit.isConfirmed(by: s))
}
@Test func reducerBlocksUnsupportedAndConflictingActions() throws {
    let c = try caps("C19ECD")
    var s = Demo.state(base: "B170"); s.spatial = 1
    #expect(throws: ControlFailure.self) { try DeviceAction.bass(true, 3).prepare(capabilities: c, state: s) }
    #expect(throws: ControlFailure.self) { try DeviceAction.eq(6).prepare(capabilities: c, state: s) }
    #expect(throws: ControlFailure.self) { try DeviceAction.codec(1).prepare(capabilities: c, state: s) }
    #expect(throws: ControlFailure.self) { try DeviceAction.personalized(true).prepare(capabilities: c, state: s) }
    let ear = try caps("FEB1C7"); s.codec = 2
    #expect(throws: ControlFailure.self) { try DeviceAction.personalSound(true).prepare(capabilities: ear, state: s) }
    s.codec = nil
    #expect(throws: ControlFailure.self) { try DeviceAction.personalSound(true).prepare(capabilities: ear, state: s) }
    #expect(throws: ControlFailure.self) { try DeviceAction.spatial(1).prepare(capabilities: ear, state: s) }
}
@Test func personalSoundAndFitResultParsers() {
    var s = DeviceState()
    for command: UInt16 in [16418, 16474, 57369, 24601] {
        s.apply(Frame(command: command, payload: [1])); #expect(s.personalSound == true)
        s.apply(Frame(command: command, payload: [0])); #expect(s.personalSound == false)
    }
    s.apply(Frame(command: 57357, payload: [0, 1]))
    #expect(s.fitLeft == .good && s.fitRight == .adjust)
    s.apply(Frame(command: 57357, payload: [255, 0]))
    #expect(s.fitLeft == .good && s.fitRight == .adjust)
}
@Test func multipointPagesAndEvents() throws {
    let payload: [UInt8] = [0, 0, 1, 0x11, 1, 2, 3, 4, 5, 6, 3, 77, 97, 99]
    let page = try #require(DualDevice.page(payload))
    #expect(page.count == 1 && page[0].name == "Mac" && page[0].isSelf && page[0].connected)
    #expect(page[0].id == "01-02-03-04-05-06")
    var s = DeviceState()
    s.apply(Frame(command: 16424, payload: payload))
    s.apply(Frame(command: 16424, payload: payload))
    #expect(s.dualDevices.count == 1)
    for count in 0..<payload.count { #expect(DualDevice.page(Array(payload.prefix(count))) == nil) }
    s.apply(Frame(command: 57358, payload: [0, 1, 2, 3, 4, 5, 6]))
    #expect(s.dualDevices[0].connected == false)
    #expect(DualDevice.page([0, 0, 0]) == [])
}
@Test func malformedFirmwareDoesNotCrash() {
    #expect(VersionRange.compare("-", "1") == nil)
    #expect(VersionRange.compare("...", "1") == nil)
    #expect(VersionRange.compare("bogus", "1") == nil)
}

@Test func apkOptionalCRCAndSixteenBitLength() {
    let frames = [Frame(command: 16391, operation: 42, payload: [1, 6, 82], control: 0x100),
                  Frame(command: 16450, operation: 43, payload: Array(repeating: 65, count: 513), control: 0x120)]
    #expect(frames[0].encoded.count == 11)
    #expect(frames[1].encoded[5...6] == [1, 2])
    var decoder = FrameDecoder()
    #expect(decoder.append(frames.flatMap(\.encoded)) == frames)
    for split in 0...frames[0].encoded.count {
        var partial = FrameDecoder()
        #expect(partial.append(Array(frames[0].encoded.prefix(split))) + partial.append(Array(frames[0].encoded.dropFirst(split))) == [frames[0]])
    }
}
@Test func apkStatusAndNormalizedNotifications() {
    var s = Demo.state(base: "B171")
    s.apply(Frame(command: 16391, payload: [1, 2, 10], control: 0x121))
    #expect(s.batteries[.left]?.percent == 86)
    s.apply(Frame(command: 24577, payload: [1, 2, 77]))
    #expect(s.batteries[.left]?.percent == 77)
    s.apply(Frame(command: 24589, payload: [1, 2]))
    #expect(s.fitLeft == .adjust && s.fitRight == .unavailable)
    #expect(Frame(command: 0xf00f).responseCommand == 0x700f)
}
@Test func apkANCTuplesAndWearFeatureOrder() {
    var s = DeviceState()
    s.apply(Frame(command: 16414, payload: [2, 4, 0, 1, 7, 0]))
    #expect(s.anc == .transparency && s.lastANC == .adaptive)
    s.apply(Frame(command: 16398, payload: [2, 8, 0, 1, 1]))
    #expect(s.inEar == true)
    #expect(Command.readPayload(Command.anc) == [3])
    #expect(Command.readPayload(Command.battery) == [])
}
@Test func apkSupportedFeaturesAndTruncatedMultipointName() throws {
    var s = DeviceState()
    s.apply(Frame(command: 16397, payload: [0, 0x40])); #expect(s.dualListSupported == true)
    s.apply(Frame(command: 16397, payload: [0, 0])); #expect(s.dualListSupported == false)
    let payload: [UInt8] = [1, 1, 1, 0x22, 1, 2, 3, 4, 5, 6, 0xff] + Array(repeating: 65, count: 31)
    let device = try #require(DualDevice.page(payload)?.first)
    #expect(!device.connected && !device.isSelf)
    #expect(device.name == String(repeating: "A", count: 31) + "…")
    #expect(Encoder.uint16(0) == [0, 0])
    #expect(Encoder.uint16(2) == [2, 0])
    #expect(Encoder.uint16(0x1234) == [0x34, 0x12])
}
@Test func apkDynamicOrdinaryEQExclusion() throws {
    let c = try caps("C19ECD")
    var s = Demo.state(base: "B170"); s.spatial = 1; s.exclusion = true
    #expect(throws: ControlFailure.self) { try DeviceAction.eq(3).prepare(capabilities: c, state: s) }
    #expect(try DeviceAction.eq(0).prepare(capabilities: c, state: s).after.eq == 0)
    #expect(try DeviceAction.eq(5).prepare(capabilities: c, state: s).after.eq == 5)
    s.exclusion = false
    #expect(try DeviceAction.eq(3).prepare(capabilities: c, state: s).after.eq == 3)
}
@Test func apkHeadphoneFrameRouteVariants() {
    #expect(FrameRoute.candidates(base: "B171") == [.web])
    #expect(FrameRoute.candidates(base: "B170") == [.web, .nativeHeadphone, .genericHeadphone])
    #expect(FrameRoute.nativeHeadphone.control == 0x0660)
    #expect(FrameRoute.genericHeadphone.payload(command: Command.firmware, bytes: []) == [6])
    #expect(FrameRoute.genericHeadphone.payload(command: Command.anc, bytes: []) == [3])
    #expect(FrameRoute.genericHeadphone.payload(command: Command.setCodec, bytes: [2, 0]) == [2, 0])
    let frame = Frame(command: 16450, payload: Array("1.0.1.75".utf8), control: 0x0620)
    var decoder = FrameDecoder()
    #expect(decoder.append(frame.encoded) == [frame])
}

@Test func nameFallbackIdentifiesPriorityDevices() throws {
    let c = try catalog()
    #expect(c.model(named: "Nothing Headphone (1)")?.base == "B170")
    #expect(c.model(named: "Nothing Ear")?.base == "B171")
    #expect(c.model(named: "  nothing ear  ")?.base == "B171")
    #expect(c.model(named: "Mav's Nothing Headphone (1)")?.base == "B170")
    #expect(c.model(named: "Nothing Ear (a)")?.base != "B171")
    #expect(c.model(named: "Logitech M720") == nil)
    #expect(c.model(named: "") == nil)
}

/// Real replies captured from a Nothing Headphone (1) (B170, firmware 1.0.1.81) on
/// RFCOMM channel 15 ("NT LINK") over both the web type-1 and native type-6 routes.
@Test func headphoneOneHardwareReplies() {
    func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
    }
    for (firmwareHex, batteryHex) in [
        ("5560014240080001312e302e312e3831a3f6", "55600107400300020106644a25"),
        ("5560064240080003312e302e312e3831bc51", "55600607400300040106646c9d"),
    ] {
        var decoder = FrameDecoder()
        let frames = decoder.append(bytes(firmwareHex) + bytes(batteryHex))
        #expect(frames.count == 2)
        #expect(decoder.rejectedPackets == 0)
        var state = DeviceState()
        for frame in frames { state.apply(frame) }
        #expect(state.firmware == "1.0.1.81")
        #expect(state.batteries[.stereo] == Battery(percent: 100, charging: false))
    }
}

/// Full web-route refresh captured from a real Headphone (1), firmware 1.0.1.81.
@Test func headphoneOneHardwareRefresh() {
    func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
    }
    let replies = [
        "5560010140060001312e302e300aa856", "55600107400300020106644a25",
        "5560014240080003312e302e312e3831ba96", "5560011f40010004051fd4",
        "5560011e40060005010500020100f3ea", "5560010e401300060901010201070109010a010b000e0112011501f723",
        "5560014140010007025398", "5560014e400200080006d25c", "5560015a4001000900d5d2",
        "556001274001000a011ecf", "5560010d4004000b43eb0200df7b", "5560014c4001000d011424",
        "5560014f4002000e0000a29f", "556001294001000f00dd71",
    ]
    var decoder = FrameDecoder()
    let frames = decoder.append(replies.flatMap(bytes))
    #expect(frames.count == replies.count)
    #expect(decoder.rejectedPackets == 0)
    #expect(frames.allSatisfy { $0.status == 0 })
    var state = DeviceState()
    for frame in frames { state.apply(frame) }
    #expect(state.firmware == "1.0.1.81")
    #expect(state.batteries == [.stereo: Battery(percent: 100, charging: false)])
    #expect(state.anc != nil)
    #expect(state.eq == 5)
    #expect(state.latency == false)
    #expect(state.bass == false)
    #expect(state.dual == true)
    #expect(state.advancedEQ == true)
    #expect(state.spatial == 0)
    #expect(state.codec == 0)
}
