import DeviceRuntime
import Testing
@testable import HushbarApp

@Test @MainActor func advancedSelectionOpensItsEditorImmediately() {
    let session = DeviceSession(demoBase: "B170", snapshot: true)
    let navigation = PanelNavigation()
    navigation.selectEQ(6, session: session)
    #expect(navigation.page == .advancedEQ)
    #expect(session.state.advancedEQ == true)
    // Device I/O must not lock navigation while a selected mode is being applied.
    session.pending.insert("eq")
    navigation.path = []
    navigation.editEQ(session: session)
    #expect(navigation.page == .advancedEQ)
    #expect(session.pending == ["eq"])
}

@Test @MainActor func advancedEditorRemainsReachableWhenActivationIsBlocked() {
    let session = DeviceSession(demoBase: "B170", snapshot: true)
    session.setSpatial(1)
    let navigation = PanelNavigation()
    navigation.selectEQ(6, session: session)
    #expect(navigation.page == .advancedEQ)
    #expect(session.state.advancedEQ == false)
    #expect(session.error != nil)
}
