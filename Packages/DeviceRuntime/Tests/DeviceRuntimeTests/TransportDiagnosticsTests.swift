import Testing
@testable import DeviceRuntime

@Test @MainActor func timeoutReportsItsCauseBeforeSessionTeardown() {
    let transport = RFCOMMTransport()
    var events: [String] = []
    var failure: String?
    transport.onFailure = { error in
        failure = (error as? BluetoothFailure)?.message
        events.append("failure")
    }
    transport.onClosed = { events.append("closed") }
    transport.timeoutReached("Bluetooth channel did not open within 12 seconds.")
    #expect(events == ["failure", "closed"])
    #expect(failure == "Bluetooth channel did not open within 12 seconds.")
    #expect(!transport.isOpen)
}
