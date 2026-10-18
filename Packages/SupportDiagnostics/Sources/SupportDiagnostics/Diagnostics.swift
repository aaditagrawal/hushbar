import Foundation
import Observation

/// Defense in depth for text shown by clients. Captured events use typed fields,
/// never arbitrary messages, Bluetooth names, error descriptions or packet bytes.
public enum DiagnosticRedactor {
    public static func redact(_ text: String, sensitiveNames: [String] = []) -> String {
        var result = text
        for name in sensitiveNames.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: name, with: "[name]", options: .caseInsensitive)
        }
        let rules: [(String, String)] = [
            (#"(?i)\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b|\b[0-9a-f]{12}\b"#, "[address]"),
            (#"(?i)\b(?:[0-9a-f]{2}[ ,]){5}[0-9a-f]{2}\b"#, "[address]"),
            (#"(?i)\b(?:[a-z]:[\\/]|file://)[^\s\"<>]+|(?:~?/)[^\s\"<>]+"#, "[path]"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]"),
            (#"[\"“‘'][^\"”’'\r\n]+[\"”’']"#, "[name]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[network address]")
        ]
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return String(result.prefix(2048))
    }

    static func matching(_ value: String, pattern: String, fallback: String = "unknown") -> String {
        guard value.range(of: pattern, options: .regularExpression) != nil else { return fallback }
        return value
    }
}

public enum DiagnosticMode: String, Codable, Sendable { case live, demo, snapshot }
public enum DiagnosticRoute: String, Codable, Sendable { case web, nativeHeadphone, genericHeadphone, fastPair, unknown }
public enum DiagnosticDirection: String, Codable, Sendable { case sent, received }
public enum DiagnosticCRC: String, Codable, Sendable { case presentAndValid, absent, rejected, notParsed }
public enum DiagnosticFailureReason: String, Codable, Sendable {
    case cancelled, timedOut, disconnected, identificationUnavailable, configurationUnavailable
    case rejected, unsupportedProfile, other
}
public enum DiagnosticCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case anc, inEar, latency, bassRead, bassWrite, personalizedANC, dual, personalSound
    case fitTest, find, customEQ, advancedEQ, spatial, codec, listeningMode
}
public enum DiagnosticKind: String, Codable, Sendable {
    case captureStarted, captureStopped, bluetoothConnected, bluetoothDisconnected
    case autoSelected, connecting, identifiedByName, identifiedByFastPair, fastPairUnavailable
    case fastPairIdentifierMissing, controlOpened, routeAttempt, routeFailed, ready, disconnected
    case reconnectScheduled, connectionFailed, compatibility, packet, parserRejected
    case acknowledgement, readSucceeded, readRejected, readTimedOut, profileRejected, editStarted, editConfirmed
    case editRolledBack, advisoryReadUnavailable, transportFailed, operationFailed
}

/// Only protocol headers survive. The API deliberately accepts no packet payload.
public struct DiagnosticPacketMetadata: Codable, Equatable, Sendable {
    public let direction: DiagnosticDirection
    public let command: UInt16?
    public let operation: UInt8?
    public let status: UInt8?
    public let byteCount: Int
    public let route: DiagnosticRoute
    public let crc: DiagnosticCRC
    public init(direction: DiagnosticDirection, command: UInt16? = nil, operation: UInt8? = nil,
                status: UInt8? = nil, byteCount: Int, route: DiagnosticRoute, crc: DiagnosticCRC = .notParsed) {
        self.direction = direction; self.command = command; self.operation = operation
        self.status = status; self.byteCount = max(0, min(byteCount, 1_000_000)); self.route = route; self.crc = crc
    }
}

public struct DiagnosticDeviceInfo: Encodable, Equatable, Sendable {
    public let base: String
    public let firmware: String
    public let capabilities: [DiagnosticCapability]
    public init(base: String, firmware: String, capabilities: [DiagnosticCapability] = []) {
        self.base = DiagnosticRedactor.matching(base, pattern: #"^[BC][0-9]{3}$"#)
        self.firmware = DiagnosticRedactor.matching(firmware, pattern: #"^[0-9]{1,6}(?:\.[0-9]{1,6}){1,5}$"#)
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
    }
}

public struct DiagnosticEnvironment: Encodable, Equatable, Sendable {
    public let appVersion: String
    public let build: String
    public let operatingSystem: String
    public let architecture: String
    public let mode: DiagnosticMode
    public init(appVersion: String, build: String, operatingSystem: String, architecture: String, mode: DiagnosticMode) {
        self.appVersion = DiagnosticRedactor.matching(appVersion, pattern: #"^[0-9]{1,6}(?:\.[0-9]{1,6}){0,4}$"#)
        self.build = DiagnosticRedactor.matching(build, pattern: #"^[0-9]{1,12}$"#)
        self.operatingSystem = DiagnosticRedactor.matching(operatingSystem, pattern: #"^(?:macOS|Linux|Windows) [0-9]{1,6}(?:\.[0-9]{1,6}){0,3}$"#)
        self.architecture = ["arm64", "x86_64"].contains(architecture) ? architecture : "unknown"
        self.mode = mode
    }
    public static func current(mode: DiagnosticMode) -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        #if os(macOS)
        let system = "macOS"
        #else
        let system = "Linux"
        #endif
        return Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                    operatingSystem: "\(system) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    architecture: architecture, mode: mode)
    }
}

public struct DiagnosticEvent: Encodable, Equatable, Sendable {
    public let sequence: Int
    public let milliseconds: Int
    public let connection: Int
    public let kind: DiagnosticKind
    public let packet: DiagnosticPacketMetadata?
    public let device: DiagnosticDeviceInfo?
    /// Numeric platform error code only; no NSError domain, userInfo or localized description.
    public let errorCode: Int?
    public let failureReason: DiagnosticFailureReason?
}

public struct DiagnosticReport: Encodable, Sendable {
    public let schemaVersion: Int
    public let app: String
    public let privacy: String
    public let compatibility: String
    public let environment: DiagnosticEnvironment
    public let device: DiagnosticDeviceInfo?
    public let startedAt: Date?
    public let capturing: Bool
    public let maximumEvents: Int
    public let maximumEventBytes: Int
    public let storedEventBytes: Int
    public let discardedEvents: Int
    public let events: [DiagnosticEvent]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public var summary: String {
        let device = device.map { "\($0.base), firmware \($0.firmware)" } ?? "No identified device"
        return """
        Hushbar support report · schema \(schemaVersion)
        App \(environment.appVersion) (build \(environment.build)) · \(environment.operatingSystem) · \(environment.architecture)
        Mode: \(environment.mode.rawValue) · \(device)
        Capture: \(capturing ? "running" : "stopped") · \(events.count) events · \(discardedEvents) discarded
        Metadata only. No raw packets, Bluetooth addresses, host names, paths or unified logs.
        Catalogue capabilities are not a hardware-support guarantee. EQ writes and ringing remain unverified.
        """
    }
    public func textData() throws -> Data {
        Data((summary + "\n\n" + String(decoding: try jsonData(), as: UTF8.self) + "\n").utf8)
    }
}

/// In-memory, opt-in and bounded by encoded event bytes and count. There is no
/// persistence, upload, unified-log reader or raw-packet mode in this package.
@MainActor @Observable
public final class DiagnosticCapture {
    public private(set) var isCapturing = false
    public private(set) var events: [DiagnosticEvent] = []
    public private(set) var storedEventBytes = 0
    public private(set) var discardedEvents = 0
    public private(set) var startedAt: Date?
    public let maximumEvents: Int
    public let maximumEventBytes: Int
    private var environment = DiagnosticEnvironment.current(mode: .live)
    private var device: DiagnosticDeviceInfo?
    private var connection = 0
    private var nextSequence = 0
    private var eventSizes: [Int] = []

    public init(maximumEvents: Int = 1000, maximumEventBytes: Int = 262_144) {
        self.maximumEvents = max(1, maximumEvents)
        self.maximumEventBytes = max(1, maximumEventBytes)
    }
    public func start(environment: DiagnosticEnvironment, device: DiagnosticDeviceInfo? = nil, now: Date = Date()) {
        reset()
        self.environment = environment; self.device = device; startedAt = now; isCapturing = true
        record(.captureStarted, now: now)
        if let device { record(.compatibility, device: device, now: now) }
    }
    public func stop(now: Date = Date()) {
        guard isCapturing else { return }
        record(.captureStopped, now: now); isCapturing = false
    }
    public func reset() {
        isCapturing = false; events.removeAll(); eventSizes.removeAll(); device = nil; startedAt = nil
        storedEventBytes = 0; discardedEvents = 0; connection = 0; nextSequence = 0
    }
    public func record(_ kind: DiagnosticKind, packet: DiagnosticPacketMetadata? = nil,
                       device: DiagnosticDeviceInfo? = nil, errorCode: Int? = nil,
                       failureReason: DiagnosticFailureReason? = nil, now: Date = Date()) {
        guard isCapturing else { return }
        if kind == .connecting || kind == .disconnected { connection += 1; self.device = nil }
        if let device { self.device = device }
        let elapsed = min(Double(Int.max / 2), max(0, now.timeIntervalSince(startedAt ?? now) * 1000))
        let event = DiagnosticEvent(sequence: nextSequence, milliseconds: Int(elapsed), connection: connection,
                                    kind: kind, packet: packet, device: device, errorCode: errorCode, failureReason: failureReason)
        nextSequence += 1
        guard let size = try? JSONEncoder().encode(event).count, size <= maximumEventBytes else { discardedEvents += 1; return }
        while !events.isEmpty && (events.count >= maximumEvents || storedEventBytes + size > maximumEventBytes) {
            events.removeFirst(); storedEventBytes -= eventSizes.removeFirst(); discardedEvents += 1
        }
        events.append(event); eventSizes.append(size); storedEventBytes += size
    }
    public func report() -> DiagnosticReport {
        DiagnosticReport(schemaVersion: 1, app: "Hushbar",
            privacy: "Metadata only; no payloads, addresses, names, paths, unified logs or automatic upload. Capture is in memory and starts empty.",
            compatibility: "Only Headphone (1) firmware 1.0.1.81 was hardware-checked. The 20 catalogue names are not guaranteed support. Advanced profile reads returned eight bands. EQ writes and ringing remain unverified.",
            environment: environment, device: device, startedAt: startedAt, capturing: isCapturing,
            maximumEvents: maximumEvents, maximumEventBytes: maximumEventBytes, storedEventBytes: storedEventBytes,
            discardedEvents: discardedEvents, events: events)
    }
}
