import Foundation
import Testing
@testable import SupportDiagnostics

private let fixtureDate = Date(timeIntervalSince1970: 1_767_225_600)
private let fixtureEnvironment = DiagnosticEnvironment(appVersion: "0.1.0", build: "7",
    operatingSystem: "macOS 14.0.0", architecture: "arm64", mode: .snapshot)

@Test func redactionRemovesAddressesPathsAndNamedHosts() {
    let input = #"Failed for Alice's Mac at AA:BB:CC:DD:EE:FF; aa-bb-cc-dd-ee-ff; AABBCCDDEEFF; /Users/alice/Library/log.txt; ~/Desktop/report; C:\Users\alice\report.json; file:///private/tmp/data; alice@example.test; 192.168.1.4"#
    let output = DiagnosticRedactor.redact(input, sensitiveNames: ["Alice's Mac"])
    for secret in ["Alice", "AA:BB", "aa-bb", "AABBCC", "/Users", "~/Desktop", "C:\\Users", "/private", "alice@", "192.168"] {
        #expect(!output.contains(secret))
    }
    #expect(output.contains("[name]") && output.contains("[address]") && output.contains("[path]"))
}

@Test func redactionHandlesQuotedNamesAndByteAddresses() {
    let output = DiagnosticRedactor.redact(#"Host "Personal laptop", address 01 23 45 67 89 AB; 'Work phone'"#)
    #expect(!output.contains("Personal laptop") && !output.contains("Work phone"))
    #expect(!output.contains("01 23 45"))
    #expect(DiagnosticRedactor.redact(String(repeating: "a", count: 5000)).count == 2048)
}

@Test func environmentAndDeviceRejectArbitraryIdentityStrings() {
    let device = DiagnosticDeviceInfo(base: "Alice's headphones AA:BB:CC:DD:EE:FF", firmware: "/Users/alice/firmware")
    #expect(device.base == "unknown" && device.firmware == "unknown")
    let environment = DiagnosticEnvironment(appVersion: "Alice", build: "host.example", operatingSystem: "/private/log",
                                            architecture: "work laptop", mode: .demo)
    #expect(environment.appVersion == "unknown" && environment.build == "unknown")
    #expect(environment.operatingSystem == "unknown" && environment.architecture == "unknown")
    let known = DiagnosticDeviceInfo(base: "B170", firmware: "1.0.1.81", capabilities: [.dual, .anc, .dual])
    #expect(known.capabilities == [.anc, .dual])
}

@Test @MainActor func captureIsDisabledUntilExplicitlyStarted() {
    let capture = DiagnosticCapture()
    capture.record(.connectionFailed, errorCode: -1)
    capture.record(.compatibility, device: .init(base: "B170", firmware: "1.0.1.81"))
    capture.stop(now: fixtureDate)
    #expect(!capture.isCapturing && capture.events.isEmpty && capture.startedAt == nil)
    #expect(capture.storedEventBytes == 0 && capture.report().device == nil)
}

@Test @MainActor func stopFreezesCaptureAndRestartClearsPreviousSession() {
    let capture = DiagnosticCapture()
    capture.start(environment: fixtureEnvironment, device: .init(base: "B170", firmware: "1.0.1.81"), now: fixtureDate)
    capture.record(.ready, now: fixtureDate.addingTimeInterval(1))
    capture.stop(now: fixtureDate.addingTimeInterval(2))
    let count = capture.events.count
    capture.record(.connectionFailed, now: fixtureDate.addingTimeInterval(3))
    #expect(capture.events.count == count && capture.events.last?.kind == .captureStopped)
    capture.start(environment: fixtureEnvironment, now: fixtureDate.addingTimeInterval(4))
    #expect(capture.events.count == 1 && capture.events.first?.sequence == 0)
    #expect(capture.report().device == nil && capture.discardedEvents == 0)
    #expect(capture.events.first?.milliseconds == 0)
}

@Test @MainActor func resetClearsReportAndStopsRecording() {
    let capture = DiagnosticCapture(maximumEvents: 2)
    capture.start(environment: fixtureEnvironment, device: .init(base: "B170", firmware: "1.0.1.81"), now: fixtureDate)
    capture.record(.ready, now: fixtureDate)
    #expect(capture.discardedEvents > 0)
    capture.reset()
    capture.record(.ready)
    #expect(!capture.isCapturing && capture.startedAt == nil && capture.events.isEmpty)
    #expect(capture.storedEventBytes == 0 && capture.discardedEvents == 0 && capture.report().device == nil)
}

@Test @MainActor func countLimitKeepsNewestEvents() {
    let capture = DiagnosticCapture(maximumEvents: 3)
    capture.start(environment: fixtureEnvironment, now: fixtureDate)
    for index in 0..<10 { capture.record(.ready, now: fixtureDate.addingTimeInterval(Double(index))) }
    #expect(capture.events.count == 3 && capture.discardedEvents == 8)
    #expect(capture.events.map(\.sequence) == [8, 9, 10])
    #expect(capture.events.map(\.milliseconds) == [7000, 8000, 9000])
}

@Test @MainActor func byteLimitCountsEncodedBytesAndKeepsNewestEvents() throws {
    let capture = DiagnosticCapture(maximumEvents: 1000, maximumEventBytes: 500)
    capture.start(environment: fixtureEnvironment, now: fixtureDate)
    for index in 0..<100 {
        capture.record(.packet, packet: .init(direction: .received, command: 49229, operation: UInt8(index),
            status: 0, byteCount: 150, route: .nativeHeadphone, crc: .presentAndValid), now: fixtureDate)
    }
    #expect(capture.events.count < 100 && capture.discardedEvents > 0 && capture.storedEventBytes <= 500)
    let sizes = try capture.events.map { try JSONEncoder().encode($0).count }
    #expect(sizes.reduce(0, +) == capture.storedEventBytes)
    #expect(capture.events.last?.sequence == 100)
}

@Test @MainActor func oversizedEventIsDroppedWithoutBreakingBounds() {
    let capture = DiagnosticCapture(maximumEvents: 0, maximumEventBytes: 1)
    capture.start(environment: fixtureEnvironment, now: fixtureDate)
    capture.record(.packet, packet: .init(direction: .received, byteCount: 10, route: .fastPair), now: fixtureDate)
    #expect(capture.maximumEvents == 1 && capture.events.isEmpty)
    #expect(capture.discardedEvents == 2 && capture.storedEventBytes == 0)
}

@Test @MainActor func reconnectSeparatesCompatibilityAndClearsStaleDevice() {
    let capture = DiagnosticCapture()
    capture.start(environment: fixtureEnvironment, device: .init(base: "B170", firmware: "1.0.1.81"), now: fixtureDate)
    capture.record(.disconnected, now: fixtureDate)
    #expect(capture.report().device == nil)
    capture.record(.connecting, now: fixtureDate)
    capture.record(.compatibility, device: .init(base: "B171", firmware: "1.2.3"), now: fixtureDate)
    #expect(capture.report().device?.base == "B171")
    let identities = capture.events.filter { $0.kind == .compatibility }
    #expect(identities.map { $0.device?.base } == ["B170", "B171"])
    #expect(identities[0].connection != identities[1].connection)
}

@Test @MainActor func packetExportContainsOnlyHeaderMetadata() throws {
    let capture = DiagnosticCapture()
    capture.start(environment: fixtureEnvironment, now: fixtureDate)
    // A payload containing a saved host name, Bluetooth address or path cannot
    // be passed to this API. Only command/status/route/header counts are accepted.
    capture.record(.packet, packet: .init(direction: .received, command: 49192, operation: 9,
        status: 0, byteCount: 120, route: .nativeHeadphone, crc: .presentAndValid), now: fixtureDate)
    let object = try #require(JSONSerialization.jsonObject(with: capture.report().jsonData()) as? [String: Any])
    let events = try #require(object["events"] as? [[String: Any]])
    let packet = try #require(events.last?["packet"] as? [String: Any])
    #expect(Set(packet.keys) == Set(["direction", "command", "operation", "status", "byteCount", "route", "crc"]))
    #expect(packet["command"] as? Int == 49192 && packet["operation"] as? Int == 9)
    #expect(packet["route"] as? String == "nativeHeadphone")
    #expect(packet["payload"] == nil && packet["hex"] == nil && packet["name"] == nil && packet["address"] == nil)
}

@Test @MainActor func deterministicJSONAndTextDescribePrivacyAndCompatibility() throws {
    let capture = DiagnosticCapture()
    capture.start(environment: fixtureEnvironment, device: .init(base: "B170", firmware: "1.0.1.81"), now: fixtureDate)
    capture.record(.readTimedOut, errorCode: -536870212, failureReason: .timedOut, now: fixtureDate.addingTimeInterval(1))
    capture.stop(now: fixtureDate.addingTimeInterval(2))
    let report = capture.report()
    let first = try report.jsonData()
    let second = try report.jsonData()
    #expect(first == second)
    let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1 && object["app"] as? String == "Hushbar")
    #expect(object["capturing"] as? Bool == false && object["events"] is [[String: Any]])
    #expect(object["startedAt"] as? String == "2026-01-01T00:00:00Z")
    #expect((object["privacy"] as? String)?.contains("no payloads") == true)
    #expect((object["compatibility"] as? String)?.contains("EQ writes and ringing remain unverified") == true)
    let text = String(decoding: try report.textData(), as: UTF8.self)
    #expect(text.hasPrefix(report.summary) && text.contains(String(decoding: first, as: UTF8.self)))
    #expect(report.summary.contains("snapshot") && report.summary.contains("B170"))
}

@Test @MainActor func invalidMetadataCannotLeakThroughReport() throws {
    let capture = DiagnosticCapture()
    capture.start(environment: .init(appVersion: "/Users/alice/app", build: "AA:BB:CC:DD:EE:FF",
        operatingSystem: "Personal Mac", architecture: "alice", mode: .snapshot),
        device: .init(base: "Personal headphones", firmware: "secret-host"), now: fixtureDate)
    let json = String(decoding: try capture.report().jsonData(), as: UTF8.self)
    for secret in ["alice", "AA:BB", "Personal", "secret-host", "/Users"] { #expect(!json.contains(secret)) }
}

@Test @MainActor func capturedReportIsAnImmutableSnapshot() throws {
    let capture = DiagnosticCapture()
    capture.start(environment: fixtureEnvironment, now: fixtureDate)
    let report = capture.report()
    let data = try report.jsonData()
    capture.record(.ready, now: fixtureDate)
    capture.reset()
    #expect(try report.jsonData() == data)
    #expect(report.events.count == 1 && report.capturing)
}
