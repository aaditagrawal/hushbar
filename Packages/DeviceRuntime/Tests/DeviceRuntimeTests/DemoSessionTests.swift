import Testing
import DeviceProtocol
@testable import DeviceRuntime

@Test @MainActor func earDemoSessionUsesAllControls() async throws {
    let session = DeviceSession(demoBase: "B171")
    #expect(session.isDemo && session.ready && !session.connecting)
    #expect(session.devices.isEmpty)
    #expect(session.model?.base == "B171")
    #expect(session.state.batteries.count == 3)
    for mode in try #require(session.capabilities).ancModes {
        session.setANC(mode); #expect(session.state.anc == mode)
    }
    for id: UInt8 in [0, 3, 2, 1, 5, 6] {
        session.setEQ(id)
        if id == 6 { #expect(session.state.advancedEQ == true) }
        else { #expect(session.state.eq == id && session.state.advancedEQ == false) }
    }
    session.setInEar(false); #expect(session.state.inEar == false)
    session.setLatency(true); #expect(session.state.latency == true)
    session.setBass(true, level: 5); #expect(session.state.bass == true && session.state.bassWire == 10)
    session.setDual(false); #expect(session.state.dual == false)
    session.setCodec(1); #expect(session.state.codec == 1)
    session.setPersonalSound(true); #expect(session.state.personalSound == true)
    session.setCodec(2); session.setPersonalSound(false); session.setPersonalSound(true)
    #expect(session.state.personalSound == false && session.error != nil)
    session.ring("left", enabled: true); session.ring("right", enabled: true)
    #expect(session.ringing == ["left", "right"])
    session.stopRinging(); #expect(session.ringing.isEmpty)
    session.setLogin(true); #expect(session.loginEnabled)
    session.setLogin(false); #expect(!session.loginEnabled)
    session.runFitTest(); #expect(session.testingFit)
    for _ in 0..<100 {
        if !session.testingFit { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(session.state.fitLeft == .good && session.state.fitRight == .good && !session.testingFit)
    #expect(session.pending.isEmpty)
}
@Test @MainActor func headphoneDemoAndModelSwitchResetState() throws {
    let session = DeviceSession(demoBase: "B170")
    #expect(session.model?.base == "B170" && session.state.batteries.count == 1)
    #expect(session.state.batteries[.stereo]?.percent == 82)
    session.setSpatial(1); #expect(session.state.spatial == 1)
    session.setBass(true); #expect(session.state.bass == false && session.error != nil)
    session.setEQ(6); #expect(session.state.advancedEQ == false)
    session.setSpatial(0); session.setBass(true); #expect(session.state.bass == true)
    session.setSpatial(2); #expect(session.state.spatial == 0)
    session.setBass(false); session.setSpatial(2); #expect(session.state.spatial == 2)
    session.setPersonalSound(true); #expect(session.state.personalSound == true)
    let phone = try #require(session.state.dualDevices.last)
    session.setDualDevice(phone, connected: true)
    #expect(session.state.dualDevices.filter(\.connected).count == 2)
    session.ring("both", enabled: true); #expect(!session.ringing.isEmpty)
    session.setDemo("B171")
    #expect(session.state.batteries.count == 3 && session.ringing.isEmpty && session.state.spatial == 0)
    session.setDemo("B170")
    #expect(session.state.batteries.count == 1 && session.state.personalSound == false)
}

@Test @MainActor func demoEqualizerEditorsWriteReadAndReset() async throws {
    for base in ["B171", "B170"] {
        let session = DeviceSession(demoBase: base)
        session.setEQ(5)
        await session.loadEqualizer(advanced: false)
        var custom = try #require(session.state.customEQ)
        custom.bands[2].gain = 3; custom.bands[0].gain = -1.5; custom.totalGain = -3
        session.setEqualizer(custom, advanced: false)
        #expect(session.state.customEQ == custom && session.pending.isEmpty && session.error == nil)
        session.setEQ(6)
        var advanced = try #require(session.state.advancedBands)
        advanced.bands[0].gain = -2; advanced.bands[4].frequency = 1500; advanced.bands[4].quality = 1.7
        session.setEqualizer(advanced, advanced: true)
        #expect(session.state.advancedBands == advanced && session.pending.isEmpty && session.error == nil)
        for index in advanced.bands.indices { advanced.bands[index].gain = 0 }
        session.setEqualizer(advanced, advanced: true)
        #expect(session.state.advancedBands?.bands.allSatisfy { $0.gain == 0 } == true)
        #expect(session.state.advancedBands?.bands[4].frequency == 1500)
        #expect(session.state.advancedBands?.totalGain == -6)
    }
}
