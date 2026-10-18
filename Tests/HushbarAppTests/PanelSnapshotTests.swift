import DeviceRuntime
import Foundation
import Testing
import DeviceProtocol
import SupportDiagnostics
@testable import HushbarApp

@Test @MainActor func snapshotArgumentsDoNotFallThroughToLiveMode() throws {
    #expect(try PanelSnapshots.requestedDirectory(environment: [:], arguments: ["Hushbar"]) == nil)
    #expect(throws: SnapshotFailure.self) {
        try PanelSnapshots.requestedDirectory(environment: [:], arguments: ["Hushbar", "--render-snapshots"])
    }
    #expect(throws: SnapshotFailure.self) {
        try PanelSnapshots.requestedDirectory(environment: ["HUSHBAR_SNAPSHOTS": " "], arguments: ["Hushbar"])
    }
    let directory = try PanelSnapshots.requestedDirectory(environment: ["HUSHBAR_SNAPSHOTS": "/unused"],
                                                         arguments: ["Hushbar", "--render-snapshots", "/snapshots"])
    #expect(directory?.path == "/snapshots")
    #expect(try PanelSnapshots.requestedDirectory(environment: ["HUSHBAR_SNAPSHOTS": "/snapshots"], arguments: ["Hushbar"]) == directory)
}

@Test @MainActor func snapshotFixturesCoverControlsAndIsolateRealState() throws {
    let keys = ["showBattery", "autoConnectLast", "lastDevice"]
    let defaults = UserDefaults.standard
    let saved = keys.map { defaults.object(forKey: $0) as? AnyHashable }
    var selectedEQ: Set<UInt8> = []
    var names: Set<String> = []
    for scenario in PanelSnapshots.scenarios {
        #expect(names.insert("\(scenario.device)-\(scenario.state)").inserted)
        let session = try scenario.makeSession()
        #expect(session.isSnapshot && session.error == nil && session.pending.isEmpty)
        if scenario.state == "settings-diagnostics" {
            let report = session.diagnostics.report()
            #expect(scenario.appSettings && !session.diagnostics.isCapturing)
            #expect(report.environment.mode == .snapshot && report.device?.base == session.model?.base)
            #expect(report.events.map(\.kind) == [.captureStarted, .compatibility, .captureStopped])
        } else {
            #expect(session.diagnostics.events.isEmpty && !session.diagnostics.isCapturing)
        }
        if scenario.device == "real" {
            #expect(!session.isDemo && !session.ready && !session.scanning)
            #expect(session.devices.isEmpty && session.selectedID == nil && session.model == nil)
            #expect(session.connecting == (scenario.state == "connecting"))
            #expect(!session.loginEnabled && !session.loginNeedsApproval)
            session.showBattery = false; session.autoConnectLast = false
        } else if scenario.device == "b171" {
            let capabilities = try #require(session.capabilities)
            #expect(session.model?.singleBattery == false && session.state.batteries.count == 3)
            #expect(capabilities.spatialModes.isEmpty && capabilities.earFit)
            if session.state.advancedEQ == true { selectedEQ.insert(6) }
            else if let eq = session.state.eq { selectedEQ.insert(eq) }
            if scenario.state == "ringing-left" { #expect(session.ringing == ["left"]) }
            if scenario.state == "connections-fit-codec" {
                #expect(session.state.fitLeft == .good && session.state.fitRight == .adjust)
                #expect(session.state.dualDevices.filter(\.connected).count == 2)
                #expect(session.state.codec == 2 && scenario.devicesExpanded)
            }
        } else {
            #expect(session.model?.singleBattery == true && session.state.batteries.count == 1)
            #expect(session.state.batteries[.chargingCase] == nil && session.capabilities?.earFit == false)
            if scenario.state == "spatial-head-tracked" {
                #expect(session.state.spatial == 1 && session.state.bass == false && session.state.advancedEQ == false)
            }
        }
    }
    #expect(selectedEQ == [0, 3, 2, 1, 5, 6])
    #expect(keys.map { defaults.object(forKey: $0) as? AnyHashable } == saved)
}

@Test @MainActor func snapshotPagesCoverNavigationForBothPriorityDevices() throws {
    for device in ["b171", "b170"] {
        for (state, page) in [("default", PanelPage.main), ("device-settings", .device), ("eq-custom", .customEQ), ("eq-advanced", .advancedEQ)] {
            let scenario = try #require(PanelSnapshots.scenarios.first { $0.device == device && $0.state == state })
            #expect(scenario.page == page)
            #expect(try scenario.makeSession().ready)
        }
        for state in ["settings-general", "settings-about", "settings-diagnostics"] {
            let scenario = try #require(PanelSnapshots.scenarios.first { $0.device == device && $0.state == state })
            #expect(scenario.appSettings && scenario.page == .main)
        }
    }
    for scenario in PanelSnapshots.scenarios where scenario.devicesExpanded {
        #expect(scenario.page == .device)
    }
}
