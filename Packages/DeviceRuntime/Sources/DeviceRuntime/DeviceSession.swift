import AppKit
import Observation
import os
import ServiceManagement
import DeviceProtocol
import SupportDiagnostics
@preconcurrency import IOBluetooth

@MainActor @Observable
public final class DeviceSession {
    public let diagnostics = DiagnosticCapture()
    public var devices: [PairedAudioDevice] = []
    public var scanning = false
    public var connecting = false
    public var ready = false
    public var status = "Choose a paired device"
    public var error: String?
    public var state = DeviceState()
    public var model: AudioDeviceModel?
    public var capabilities: Capabilities?
    public var selectedID: String?
    public var pending: Set<String> = []
    public var ringing: Set<String> = []
    public var showBattery: Bool { didSet { if !isDemo && !isSnapshot { defaults.set(showBattery, forKey: "showBattery") } } }
    public var developerSettings = false
    public var loginEnabled = false
    public var loginNeedsApproval = false
    public let isSnapshot: Bool
    public var isDemo: Bool
    public var demoBase = "B171"
    public var autoConnectLast: Bool {
        didSet {
            guard !isDemo, !isSnapshot else { return }
            defaults.set(autoConnectLast, forKey: "autoConnectLast")
            if autoConnectLast { autoConnect() } else { reconnectTask?.cancel(); reconnectTask = nil }
        }
    }
    public var testingFit = false
    public var loadingDual = false
    public var refreshing = false
    public private(set) var frameRoute: FrameRoute = .web
    @ObservationIgnored private let log = Logger(subsystem: "io.github.aaditagrawal.hushbar", category: "session")
    @ObservationIgnored private var lastFailure: [String: Date] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let discovery = DeviceDiscovery()
    @ObservationIgnored private let fastPair = RFCOMMTransport()
    @ObservationIgnored private let control = RFCOMMTransport()
    @ObservationIgnored private let catalog: ModelCatalog?
    @ObservationIgnored private var decoder = FrameDecoder()
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var retry = 0
    @ObservationIgnored private var mayBeRinging = false
    @ObservationIgnored private var ringEpoch = UUID()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: UInt8 = 0
    @ObservationIgnored private var lastResponses: [UInt16: Frame] = [:]
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    @ObservationIgnored private var dualTask: Task<Void, Never>?
    public var selectedName: String { model?.name ?? devices.first(where: { $0.id == selectedID })?.name ?? "Hushbar" }
    public var symbol: String { model?.singleBattery == true ? "headphones" : "earbuds" }

    public var diagnosticDeviceInfo: DiagnosticDeviceInfo? {
        guard let model else { return nil }
        var supported: [DiagnosticCapability] = []
        if let c = capabilities {
            let flags: [(DiagnosticCapability, Bool)] = [
                (.anc, c.anc), (.inEar, c.inEar), (.latency, c.latency), (.bassRead, c.bassReadable),
                (.bassWrite, c.bassWritable), (.personalizedANC, c.personalizedANC), (.dual, c.dual),
                (.personalSound, c.personalSoundRead != nil), (.fitTest, c.earFit), (.find, c.find),
                (.customEQ, c.customEQ), (.advancedEQ, c.advancedEQ), (.spatial, !c.spatialModes.isEmpty),
                (.codec, !c.codecChoices.isEmpty), (.listeningMode, c.listeningMode)
            ]
            supported = flags.filter(\.1).map(\.0)
        }
        return DiagnosticDeviceInfo(base: model.base, firmware: state.firmware, capabilities: supported)
    }
    /// Starts a fresh memory-only capture. Snapshot/demo capture uses no system
    /// preferences, login registration, device discovery or Bluetooth operations.
    public func startDiagnosticCapture() {
        diagnostics.start(environment: .current(mode: isSnapshot ? .snapshot : isDemo ? .demo : .live),
                          device: diagnosticDeviceInfo)
    }
    private func diagnose(_ kind: DiagnosticKind, packet: DiagnosticPacketMetadata? = nil, error: (any Error)? = nil) {
        var code = error.map { ($0 as NSError).code }
        let reason: DiagnosticFailureReason?
        if error is CancellationError { reason = .cancelled }
        else if let failure = error as? BluetoothFailure {
            let message = failure.message.lowercased()
            if message.contains("timed out") || message.contains("within") { reason = .timedOut }
            else if message.contains("disconnected") || message.contains("closed") { reason = .disconnected }
            else if message.contains("could not identify") { reason = .identificationUnavailable }
            else if message.contains("configuration") || message.contains("catalog") { reason = .configurationUnavailable }
            else if message.contains("rejected") || message.contains("declined") { reason = .rejected }
            else if message.contains("unsupported eq") { reason = .unsupportedProfile }
            else { reason = .other }
            if message.hasPrefix("rfcomm open failed") || message.hasPrefix("could not open rfcomm"),
               let range = message.range(of: #"\(-?[0-9]{1,12}\)"#, options: .regularExpression) {
                code = Int(message[range].dropFirst().dropLast())
            }
        } else { reason = error == nil ? nil : .other }
        diagnostics.record(kind, packet: packet, errorCode: code, failureReason: reason)
        // OS logs obey the same privacy boundary even when capture is disabled.
        // No localized errors, addresses, selected names, identifiers or hex dumps.
        if let packet {
            log.debug("\(kind.rawValue, privacy: .public) \(packet.direction.rawValue, privacy: .public) command=\(Int(packet.command ?? 0)) op=\(Int(packet.operation ?? 0)) status=\(Int(packet.status ?? 0)) bytes=\(packet.byteCount) route=\(packet.route.rawValue, privacy: .public) crc=\(packet.crc.rawValue, privacy: .public)")
        } else {
            log.debug("\(kind.rawValue, privacy: .public) reason=\(reason?.rawValue ?? "none", privacy: .public) errorCode=\(code ?? 0)")
        }
    }
    private func diagnoseRead(_ kind: DiagnosticKind, command: UInt16, operation: UInt8, status: UInt8? = nil) {
        diagnose(kind, packet: DiagnosticPacketMetadata(direction: .received, command: command,
            operation: operation, status: status, byteCount: 0,
            route: DiagnosticRoute(rawValue: frameRoute.rawValue) ?? .unknown))
    }

    public init(demoBase: String? = Demo.requestedBase(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments), snapshot: Bool = false) {
        let demo = demoBase != nil
        isSnapshot = snapshot
        isDemo = demo
        autoConnectLast = snapshot ? true : defaults.object(forKey: "autoConnectLast") as? Bool ?? true
        showBattery = snapshot ? true : defaults.object(forKey: "showBattery") as? Bool ?? true
        selectedID = demo || snapshot ? nil : defaults.string(forKey: "lastDevice")
        do { catalog = try ModelCatalog() }
        catch { catalog = nil; self.error = "Could not load bundled device data: \(error.localizedDescription)" }
        discovery.onDevices = { [weak self] devices, scanning in
            guard let self, !isDemo, !isSnapshot else { return }
            self.devices = devices; self.scanning = scanning
            autoConnect()
        }
        discovery.onConnection = { [weak self] address, connected in
            guard let self, !isDemo, !isSnapshot else { return }
            diagnose(connected ? .bluetoothConnected : .bluetoothDisconnected)
            if connected {
                lastFailure[address] = nil
                if address == selectedID { retry = 0 }
                autoConnect()
            } else if address == selectedID {
                tearDown(); status = "Waiting for your device to connect to this Mac"
                autoConnect()
            }
        }
        control.onData = { [weak self] bytes in self?.receive(bytes) }
        control.onFailure = { [weak self] error in self?.diagnose(.transportFailed, error: error) }
        control.onClosed = { [weak self] in
            guard let self else { return }
            tearDown(); status = "Connection lost. Waiting to reconnect…"; scheduleReconnect()
        }
        if let demoBase { setDemo(demoBase) }
        else if !snapshot { refreshLoginStatus(); discovery.start() }
    }
    public func refreshDevices() { if !isDemo && !isSnapshot { discovery.refresh() } }
    public func connect(_ device: PairedAudioDevice) {
        guard !isDemo, !isSnapshot else { return }
        Task { [weak self] in
            guard let self else { return }
            await stopBeforeLeaving()
            selectedID = device.id; defaults.set(device.id, forKey: "lastDevice")
            retry = 0; beginConnection(device)
        }
    }
    /// Auto-discovery: whenever nothing is connected, attach to a compatible paired device that
    /// is currently connected to this Mac — the remembered one first, otherwise any other.
    /// Devices that failed recently are skipped so a broken device can't cause a reconnect loop
    /// (scheduleReconnect handles bounded retries for those).
    private func autoConnect() {
        guard !isDemo, !isSnapshot, autoConnectLast, !ready, !connecting, reconnectTask == nil else { return }
        let live = devices.filter { device in
            device.connected && IOBluetoothDevice(addressString: device.id)?.isConnected() == true
                && (lastFailure[device.id].map { Date().timeIntervalSince($0) > 60 } ?? true)
        }
        guard let device = live.first(where: { $0.id == selectedID }) ?? live.first else { return }
        if selectedID != device.id {
            diagnose(.autoSelected)
            selectedID = device.id; defaults.set(device.id, forKey: "lastDevice")
        }
        beginConnection(device)
    }
    private func beginConnection(_ item: PairedAudioDevice) {
        guard !isDemo, !isSnapshot else { return }
        tearDown(); model = nil; error = nil; connecting = true; status = "Identifying device…"
        let token = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let catalog else { throw BluetoothFailure(message: "The bundled device catalog is unavailable.") }
                guard let device = IOBluetoothDevice(addressString: item.id) else { throw BluetoothFailure(message: "This paired device is no longer available.") }
                diagnose(.connecting)
                // Identify the model from the Bluetooth name first: Nothing X doesn't use Fast
                // Pair for settings, and macOS refuses to open the Fast Pair RFCOMM service on some
                // devices (Headphone (1) returns 0xe00002bc on it). Fast Pair is only a fallback
                // for renamed devices.
                var found = catalog.model(named: item.name)
                if found != nil { diagnose(.identifiedByName) }
                if found == nil, let channel = item.fastPairChannel {
                    var pairDecoder = FastPairDecoder()
                    var identifier: String?
                    fastPair.onData = { [weak self] bytes in
                        guard let self, token == generation else { return }
                        diagnose(.packet, packet: DiagnosticPacketMetadata(direction: .received, byteCount: bytes.count, route: .fastPair))
                        if let id = pairDecoder.append(bytes) { identifier = id }
                    }
                    do {
                        try await fastPair.open(device: device, channelID: channel)
                        for _ in 0..<60 {
                            if identifier != nil { break }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { diagnose(.fastPairUnavailable, error: error) }
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    fastPair.close(); fastPair.onData = nil
                    if let identifier {
                        found = catalog.model(id: identifier)
                        diagnose(.identifiedByFastPair)
                    } else {
                        diagnose(.fastPairIdentifierMissing)
                    }
                }
                guard let found else {
                    throw BluetoothFailure(message: "Could not identify \(item.name) as a supported Nothing or CMF model. If you renamed it, restore its original name in Bluetooth settings.")
                }
                model = found; status = "Opening control channel…"
                diagnostics.record(.compatibility, device: diagnosticDeviceInfo)
                try await control.open(device: device, channelID: item.controlChannel)
                diagnose(.controlOpened)
                try Task.checkCancellation()
                guard token == generation else { return }
                status = "Reading firmware and settings…"
                let routes = FrameRoute.candidates(base: found.base)
                for route in routes {
                    guard token == generation else { return }
                    frameRoute = route; state = DeviceState(); error = nil
                    diagnose(.routeAttempt)
                    do {
                        // Negotiate with harmless queries; never probe by changing a setting.
                        try await send(Command.handshake)
                        try await Task.sleep(for: .milliseconds(100))
                        try await send(Command.battery)
                        try await Task.sleep(for: .milliseconds(100))
                        let firmware = try await read(Command.firmware, token: token)
                        state.apply(firmware)
                        guard !state.firmware.isEmpty else { throw BluetoothFailure(message: "The device returned an empty firmware version.") }
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard token == generation else { return }
                        diagnose(.routeFailed, error: error)
                        if route == routes.last { throw error }
                    }
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                guard let config = catalog.config(base: found.base, firmware: state.firmware), !state.firmware.isEmpty else {
                    throw BluetoothFailure(message: "No compatible firmware configuration was received. Refresh to retry.")
                }
                capabilities = Capabilities(model: found, config: config, firmware: state.firmware)
                diagnostics.record(.compatibility, device: diagnosticDeviceInfo)
                if found.base != "B181" {
                    try await send(Command.utc, Encoder.utc(seconds: UInt32(Date().timeIntervalSince1970)))
                }
                try await refreshState()
                guard token == generation else { return }
                connecting = false; ready = true; retry = 0; status = "Connected"
                diagnose(.ready)
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)); try await self?.refreshState() }
                        catch { return }
                    }
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                diagnose(.connectionFailed, error: error)
                lastFailure[item.id] = Date()
                tearDown(); self.error = error.localizedDescription; status = "Could not connect"; scheduleReconnect()
            }
        }
    }
    private func tearDown() {
        diagnose(.disconnected)
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        pollTask?.cancel(); pollTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        fastPair.close(); fastPair.onData = nil; control.close(); decoder.reset()
        fitTask?.cancel(); fitTask = nil; dualTask?.cancel(); dualTask = nil
        testingFit = false; loadingDual = false; refreshing = false
        state = DeviceState(); capabilities = nil; lastResponses.removeAll()
        ready = false; connecting = false; pending.removeAll(); ringing.removeAll()
    }
    private func scheduleReconnect() {
        guard !isDemo, !isSnapshot, autoConnectLast, retry < 6, let selectedID, IOBluetoothDevice(addressString: selectedID)?.isConnected() == true else { return }
        retry += 1
        diagnose(.reconnectScheduled)
        let delay = min(30, retry * 5)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            reconnectTask = nil
            if let item = devices.first(where: { $0.id == selectedID }), IOBluetoothDevice(addressString: selectedID)?.isConnected() == true { beginConnection(item) }
        }
    }
    public func retryConnection() {
        guard !isDemo, !isSnapshot else { return }
        if let item = devices.first(where: { $0.id == selectedID }) { retry = 0; beginConnection(item) }
        else { refreshDevices() }
    }
    public func refreshSettings() {
        guard ready, !isDemo else { return }
        Task { [weak self] in
            guard let self else { return }
            let token = generation
            do { try await refreshState() }
            catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    private func receive(_ bytes: [UInt8]) {
        let rejected = decoder.rejectedPackets
        for frame in decoder.append(bytes) {
            let metadata = DiagnosticPacketMetadata(direction: .received, command: frame.command,
                operation: frame.operation, status: frame.status, byteCount: frame.payload.count + 8 + (frame.hasCRC ? 2 : 0),
                route: frame.control >> 8 == 6 ? .nativeHeadphone : DiagnosticRoute(rawValue: frameRoute.rawValue) ?? .unknown,
                crc: frame.hasCRC ? .presentAndValid : .absent)
            diagnose(.packet, packet: metadata)
            if frame.responseCommand & 0x7000 == 0x7000 { diagnose(.acknowledgement, packet: metadata) }
            lastResponses[frame.responseCommand] = frame
            state.apply(frame)
            if frame.status != 0 { error = String(format: "Device rejected command %04X, status %d.", frame.responseCommand, frame.status) }
            if frame.responseCommand == 24589 && state.fitLeft != nil { testingFit = false; fitTask?.cancel(); fitTask = nil }
            if frame.responseCommand == 24590, frame.payload.count >= 8, frame.payload[7] != 0 { refreshDualDevices() }
        }
        if decoder.rejectedPackets > rejected {
            diagnose(.parserRejected, packet: DiagnosticPacketMetadata(direction: .received, byteCount: bytes.count,
                route: DiagnosticRoute(rawValue: frameRoute.rawValue) ?? .unknown, crc: .rejected))
            error = "A Bluetooth packet failed CRC validation. Refresh if settings stop updating."
        }
    }
    @discardableResult
    private func send(_ command: UInt16, _ payload: [UInt8] = [], route: FrameRoute? = nil) async throws -> UInt8 {
        guard !isDemo, !isSnapshot else { throw CancellationError() }
        try Task.checkCancellation()
        operation = operation >= 253 ? 0 : operation + 1
        let id = operation
        let route = route ?? frameRoute
        let encoded = Frame(command: command, operation: id, payload: route.payload(command: command, bytes: payload), control: route.control).encoded
        diagnose(.packet, packet: DiagnosticPacketMetadata(direction: .sent, command: command, operation: id,
            byteCount: encoded.count, route: DiagnosticRoute(rawValue: route.rawValue) ?? .unknown))
        do { try await control.write(encoded) }
        catch { diagnose(.transportFailed, error: error); throw error }
        return id
    }
    private func read(_ command: UInt16, payload: [UInt8] = [], token: UUID) async throws -> Frame {
        guard token == generation else { throw CancellationError() }
        let response = command & 0x7fff
        lastResponses[response] = nil
        let id = try await send(command, payload)
        for _ in 0..<100 {
            guard token == generation else { throw CancellationError() }
            if let frame = lastResponses[response], frame.operation == id {
                guard frame.status == 0 else {
                    diagnoseRead(.readRejected, command: command, operation: id, status: frame.status)
                    throw BluetoothFailure(message: "The device rejected command \(String(command, radix: 16)).")
                }
                if command == Command.customEQ || command == Command.advancedBands {
                    guard EqualizerProfile.decode(frame.payload, advanced: command == Command.advancedBands) != nil else {
                        diagnoseRead(.profileRejected, command: command, operation: id)
                        throw BluetoothFailure(message: "The device returned an unsupported EQ profile.")
                    }
                }
                diagnoseRead(.readSucceeded, command: command, operation: id, status: frame.status)
                return frame
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        diagnoseRead(.readTimedOut, command: command, operation: id)
        throw BluetoothFailure(message: "The device did not reply within five seconds.")
    }
    private func refreshState() async throws {
        guard let c = capabilities, pending.isEmpty, !refreshing else { return }
        let token = generation
        refreshing = true
        defer { if token == generation { refreshing = false } }
        var commands: [UInt16] = [Command.battery, c.listeningMode ? Command.listeningMode : Command.eq]
        if c.anc { commands.append(Command.anc) }
        if c.inEar { commands.append(Command.inEar) }
        if c.latency { commands.append(Command.latency) }
        if c.bassReadable { commands.append(Command.bass) }
        if c.personalizedANC { commands.append(Command.personalizedANC) }
        if let read = c.personalSoundRead { commands.append(read) }
        if c.dual { commands += [Command.dual, Command.supportedFeatures] }
        if c.config.mutuallyExclusive == 1 { commands.append(Command.exclusion) }
        if c.advancedEQ { commands.append(Command.advancedEQ) }
        if !c.spatialModes.isEmpty { commands.append(Command.spatial) }
        if !c.codecChoices.isEmpty { commands.append(Command.codec) }
        if c.config.supportStudio == 1 { commands.append(Command.flatEQ) }
        if c.config.longPowerMode == 1 { commands.append(Command.longPower) }
        if c.config.supportLeakageProtection == 1 { commands.append(Command.antiLeakage) }
        for command in commands {
            guard token == generation, pending.isEmpty else { return }
            try await send(command); try await Task.sleep(for: .milliseconds(100))
        }
    }
    /// One edit at a time also makes cross-feature exclusions atomic.
    private func edit(_ action: DeviceAction) {
        guard ready, pending.isEmpty, let capabilities else { return }
        let edit: DeviceEdit
        do { edit = try action.prepare(capabilities: capabilities, state: state) }
        catch { self.error = error.localizedDescription; return }
        edit.apply(to: &state); error = nil
        if isDemo { return }
        pending.insert(action.key)
        diagnose(.editStarted)
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { pending.remove(action.key) } }
            do {
                // Current APK firmware can dynamically exclude ordinary EQ presets.
                // Refresh dependencies before writing, including changes made by Nothing X.
                if capabilities.config.mutuallyExclusive == 1 {
                    let dependencies: [UInt16]
                    switch action {
                    case .eq, .bass, .customEQ, .advancedBands: dependencies = [Command.spatial, Command.exclusion]
                    case .spatial(let id): dependencies = id == 0 ? [] : [Command.bass, Command.advancedEQ, Command.exclusion]
                    default: dependencies = []
                    }
                    var current = edit.before
                    for command in dependencies {
                        do { current.apply(try await read(command, token: token)) }
                        catch let error as BluetoothFailure where command == Command.exclusion {
                            // Headphone (1) firmware 1.0.1.81 never answers C062; treat it as
                            // advisory rather than blocking every EQ and bass change.
                            diagnose(.advisoryReadUnavailable, error: error)
                        }
                    }
                    _ = try action.prepare(capabilities: capabilities, state: current)
                }
                var sent: [(UInt16, UInt8)] = []
                for packet in edit.packets {
                    guard token == generation else { return }
                    let response = packet.command & 0x7fff
                    lastResponses[response] = nil
                    let id = try await send(packet.command, packet.payload)
                    sent.append((response, id))
                }
                guard token == generation else { return }
                if edit.reboot { status = "Applying change. Device may restart…" }
                try await Task.sleep(for: .milliseconds(edit.reboot ? 1200 : 150))
                var confirmed = edit.before
                for request in edit.reads {
                    confirmed.apply(try await read(request, token: token))
                }
                for (command, id) in sent {
                    if let ack = lastResponses[command], ack.operation == id, ack.status != 0 {
                        throw BluetoothFailure(message: "The device rejected the setting.")
                    }
                }
                guard edit.isConfirmed(by: confirmed) else {
                    throw BluetoothFailure(message: "The device declined the change.")
                }
                edit.apply(to: &state); status = "Connected"
                diagnose(.editConfirmed)
                if capabilities.config.mutuallyExclusive == 1 { try await send(Command.exclusion) }
            } catch {
                guard token == generation else { return }
                diagnose(.editRolledBack, error: error)
                edit.rollback(&state); self.error = "\(error.localizedDescription) The previous setting was restored."
                if edit.packets.count > 1 {
                    // A partly applied EQ transaction must be reconciled from hardware.
                    for request in edit.reads {
                        guard token == generation else { return }
                        _ = try? await send(request)
                    }
                }
                status = "Connected"
            }
        }
    }
    public func loadEqualizer(advanced: Bool) async {
        guard !isDemo, ready else { return }
        let token = generation
        do {
            for _ in 0..<300 {
                guard token == generation else { return }
                if pending.isEmpty && !refreshing { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard token == generation else { return }
            guard pending.isEmpty, !refreshing else {
                error = "Another setting is still being applied. Read from device to retry."
                return
            }
            pending.insert("eqLoad")
            error = nil
            defer { if token == generation { pending.remove("eqLoad") } }
            let frame = try await read(advanced ? Command.advancedBands : Command.customEQ, token: token)
            guard token == generation else { return }
            state.apply(frame)
        } catch {
            if token == generation && !Task.isCancelled { self.error = "Could not read EQ bands. \(error.localizedDescription)" }
        }
    }
    public func setEqualizer(_ profile: EqualizerProfile, advanced: Bool) {
        edit(advanced ? .advancedBands(profile) : .customEQ(profile))
    }
    public func setANC(_ mode: ANCMode) { edit(.anc(mode)) }
    public func setEQ(_ value: UInt8) { edit(.eq(value)) }
    public func setInEar(_ enabled: Bool) { edit(.inEar(enabled)) }
    public func setLatency(_ enabled: Bool) { edit(.latency(enabled)) }
    public func setBass(_ enabled: Bool, level: Int? = nil) { edit(.bass(enabled, level)) }
    public func setPersonalized(_ enabled: Bool) { edit(.personalized(enabled)) }
    public func setDual(_ enabled: Bool) { edit(.dual(enabled)) }
    public func setSpatial(_ id: Int) { edit(.spatial(id)) }
    public func setCodec(_ value: UInt8) { edit(.codec(value)) }
    public func setPersonalSound(_ enabled: Bool) { edit(.personalSound(enabled)) }
    public func ring(_ side: String, enabled: Bool) {
        guard ready, let model, capabilities?.find == true else { return }
        let previous = ringing
        if enabled { mayBeRinging = true }
        if !enabled { ringEpoch = UUID() }
        let epoch = ringEpoch
        if enabled { ringing.insert(side) } else { ringing.remove(side) }
        if isDemo { return }
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let sides = side == "both" && model.base != "B181" && !model.singleBattery ? [true, false] : [side == "left"]
                // Nothing X drives Headphone (1) over the native type-6 frame route; other settings
                // work on the web route, so for ringing send on both and let the firmware act on
                // whichever it honours. Repeating the same set command is idempotent.
                let routes = FrameRoute.candidates(base: model.base).count > 1 && frameRoute != .nativeHeadphone
                    ? [frameRoute, .nativeHeadphone] : [frameRoute]
                for left in sides {
                    for route in routes {
                        guard token == generation, !enabled || epoch == ringEpoch else { return }
                        try await send(Command.ring, Encoder.ring(base: model.base, enabled: enabled, left: left), route: route)
                    }
                }
                if !enabled && side == "both" { mayBeRinging = false }
            } catch { if token == generation { ringing = previous; self.error = error.localizedDescription } }
        }
    }
    public func stopRinging() {
        // Always transmit both stops, including after partial failure of a Both request.
        ring("both", enabled: false); ringing.removeAll()
    }
    public func runFitTest() {
        guard ready, capabilities?.earFit == true, !testingFit else { return }
        state.fitLeft = nil; state.fitRight = nil; testingFit = true; error = nil
        let token = generation
        fitTask = Task { [weak self] in
            guard let self else { return }
            do {
                if isDemo {
                    try await Task.sleep(for: .seconds(2))
                    guard token == generation else { return }
                    state.apply(Frame(command: 57357, payload: [0, 0])); testingFit = false
                } else {
                    try await send(Command.earFit, [1])
                    try await Task.sleep(for: .seconds(25))
                    guard token == generation else { return }
                    testingFit = false; error = "No fit result received. Insert both earbuds and try again."
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                testingFit = false; self.error = error.localizedDescription
            }
        }
    }
    public func refreshDualDevices() {
        guard ready, capabilities?.dual == true, state.dualListSupported == true, !loadingDual else { return }
        if isDemo { return }
        loadingDual = true
        let token = generation
        dualTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { loadingDual = false } }
            var next = DeviceState()
            do {
                var page = 0
                for _ in 0..<20 {
                    guard token == generation else { return }
                    let frame = try await read(Command.dualList, payload: Encoder.uint16(UInt16(page)), token: token)
                    guard DualDevice.page(frame.payload) != nil else {
                        throw BluetoothFailure(message: "Could not read remembered devices. Refresh to retry.")
                    }
                    next.apply(frame)
                    let nextPage = Int(frame.payload[1]) + 1
                    if nextPage >= Int(frame.payload[0]) { state.dualDevices = next.dualDevices; return }
                    guard nextPage > page else { throw BluetoothFailure(message: "The device repeated a multipoint page. Refresh to retry.") }
                    page = nextPage
                }
                state.dualDevices = next.dualDevices
            } catch { if token == generation { self.error = error.localizedDescription } }
        }
    }
    public func setDualDevice(_ device: DualDevice, connected: Bool) {
        guard ready, state.dual == true, state.dualListSupported == true, pending.isEmpty, !loadingDual, device.address.count == 6 else { return }
        if connected && state.dualDevices.filter(\.connected).count >= 2 { error = "Two devices are already connected."; return }
        guard let index = state.dualDevices.firstIndex(where: { $0.id == device.id }) else { return }
        state.dualDevices[index].connected = connected
        if isDemo { return }
        pending.insert("dualDevice")
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { pending.remove("dualDevice") } }
            do {
                guard token == generation else { return }
                try await send(Command.setDualDevice, [connected ? 1 : 0] + device.address)
                try await Task.sleep(for: .milliseconds(300))
                guard token == generation else { return }
                refreshDualDevices()
            } catch {
                guard token == generation else { return }
                if let index = state.dualDevices.firstIndex(where: { $0.id == device.id }) { state.dualDevices[index] = device }
                self.error = error.localizedDescription
            }
        }
    }
    /// Option-click Settings reveals this switch. Demo never persists preferences.
    public func setDemoEnabled(_ enabled: Bool) {
        guard !isSnapshot, enabled != isDemo else { return }
        if enabled {
            Task { [weak self] in
                guard let self else { return }
                await stopBeforeLeaving()
                diagnostics.reset()
                tearDown(); discovery.stop(); isDemo = true; setDemo("B171")
            }
        } else {
            diagnostics.reset()
            tearDown(); isDemo = false; model = nil
            selectedID = defaults.string(forKey: "lastDevice")
            showBattery = defaults.object(forKey: "showBattery") as? Bool ?? true
            autoConnectLast = defaults.object(forKey: "autoConnectLast") as? Bool ?? true
            refreshLoginStatus(); status = "Choose a paired device"; discovery.start()
        }
    }
    public func forget() {
        guard !isDemo, !isSnapshot else { return }
        Task { [weak self] in
            guard let self else { return }
            await stopBeforeLeaving()
            tearDown(); model = nil; selectedID = nil
            defaults.removeObject(forKey: "lastDevice"); error = nil; status = "Choose a paired device"
        }
    }
    public func setLogin(_ enabled: Bool) {
        if isDemo || isSnapshot { loginEnabled = enabled; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Login item: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    public func refreshLoginStatus() {
        guard !isDemo, !isSnapshot else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    private func stopBeforeLeaving() async {
        guard mayBeRinging, !isDemo, !isSnapshot, control.isOpen, let model else { return }
        let sides = model.singleBattery || model.base == "B181" ? [true] : [true, false]
        let token = generation
        for left in sides {
            guard token == generation else { return }
            _ = try? await send(Command.ring, Encoder.ring(base: model.base, enabled: false, left: left))
        }
        mayBeRinging = false; ringing.removeAll()
    }
    public func quit() {
        Task { [weak self] in
            await self?.stopBeforeLeaving()
            NSApplication.shared.terminate(nil)
        }
    }
    public func setDemo(_ base: String) {
        guard isDemo, let catalog else { return }
        tearDown()
        loginEnabled = false; loginNeedsApproval = false; mayBeRinging = false
        demoBase = base
        let id = base == "B170" ? "C19ECD" : "FEB1C7"
        model = catalog.model(id: id)
        state = Demo.state(base: base)
        if let model, let config = catalog.config(base: base, firmware: state.firmware) { capabilities = Capabilities(model: model, config: config, firmware: state.firmware) }
        diagnostics.record(.compatibility, device: diagnosticDeviceInfo)
        ready = true; connecting = false; error = nil; ringing.removeAll(); status = "Demo · no Bluetooth activity"
    }
}
