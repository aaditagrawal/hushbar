import Foundation
import Testing
import DeviceProtocol
@testable import DeviceRuntime

@Test @MainActor func snapshotDiagnosticsAreOptInAndUseOnlyCompatibilityMetadata() throws {
    let session = DeviceSession(demoBase: "B170", snapshot: true)
    #expect(session.diagnostics.events.isEmpty && !session.diagnostics.isCapturing)
    session.startDiagnosticCapture()
    let report = session.diagnostics.report()
    #expect(report.environment.mode.rawValue == "snapshot")
    #expect(report.device?.base == "B170" && report.device?.firmware == session.state.firmware)
    #expect(report.device?.capabilities.isEmpty == false)
    let json = String(decoding: try report.jsonData(), as: UTF8.self)
    for host in session.state.dualDevices { #expect(!json.contains(host.name)) }
    session.diagnostics.stop()
    #expect(!session.diagnostics.isCapturing)
}

@Test @MainActor func snapshotCaptureResetsAndDemoModelSwitchKeepsIdentitiesSeparate() {
    let session = DeviceSession(demoBase: "B170", snapshot: true)
    session.startDiagnosticCapture()
    session.setDemo("B171")
    let identities = session.diagnostics.events.filter { $0.kind.rawValue == "compatibility" }
    #expect(identities.map { $0.device?.base } == ["B170", "B171"])
    #expect(identities.first?.connection != identities.last?.connection)
    #expect(session.diagnostics.report().device?.base == "B171")
    session.startDiagnosticCapture()
    #expect(session.diagnostics.events.count == 2)
    #expect(session.diagnostics.events.first?.sequence == 0)
    #expect(session.diagnostics.report().device?.base == "B171")
    session.diagnostics.reset()
    #expect(session.diagnostics.events.isEmpty && session.diagnostics.report().device == nil)
}

@Test @MainActor func snapshotWithoutDemoNeverStartsDiscoveryOrPersistsPreferences() {
    let keys = ["autoConnectLast", "showBattery", "lastDevice"]
    let before = keys.map { UserDefaults.standard.object(forKey: $0) as? AnyHashable }
    let session = DeviceSession(demoBase: nil, snapshot: true)
    session.startDiagnosticCapture()
    session.refreshDevices(); session.retryConnection(); session.setDemoEnabled(true)
    session.setLogin(true); session.refreshLoginStatus()
    session.showBattery = false; session.autoConnectLast = false
    session.connect(.init(id: "00:11:22:33:44:55", name: "Example device", connected: true, controlChannel: 1))
    session.forget()
    #expect(session.devices.isEmpty && !session.scanning && !session.connecting && !session.ready)
    #expect(!session.isDemo && session.diagnostics.report().environment.mode.rawValue == "snapshot")
    #expect(session.diagnostics.report().device == nil)
    #expect(session.selectedID == nil)
    #expect(keys.map { UserDefaults.standard.object(forKey: $0) as? AnyHashable } == before)
}
