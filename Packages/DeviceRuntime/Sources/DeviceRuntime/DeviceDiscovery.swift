import Foundation
import os
@preconcurrency import IOBluetooth

public struct PairedAudioDevice: Identifiable, Equatable, Sendable {
    public let id: String, name: String
    public let connected: Bool
    public let controlChannel: BluetoothRFCOMMChannelID
    public let fastPairChannel: BluetoothRFCOMMChannelID?

    public init(id: String, name: String, connected: Bool, controlChannel: BluetoothRFCOMMChannelID,
                fastPairChannel: BluetoothRFCOMMChannelID? = nil) {
        self.id = id; self.name = name; self.connected = connected
        self.controlChannel = controlChannel; self.fastPairChannel = fastPairChannel
    }
}

@MainActor
final class DeviceDiscovery: NSObject {
    static let controlUUID = uuid("aeac4a03dff5498f843a34487cf133eb")
    static let fastPairUUID = uuid("df21fe2c25154fdb8886f12c4d67927c")
    static let log = Logger(subsystem: "io.github.aaditagrawal.hushbar", category: "discovery")
    var onDevices: (([PairedAudioDevice], Bool) -> Void)?
    var onConnection: ((String, Bool) -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: PairedAudioDevice] = [:]
    private var pending: Set<String> = []
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var started = false
    private var rescanTask: Task<Void, Never>?
    private static func uuid(_ hex: String) -> IOBluetoothSDPUUID {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return IOBluetoothSDPUUID(data: Data(bytes))
    }
    func start() {
        guard !started else { return }
        started = true
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        refresh()
        // Until a compatible device shows up, rescan periodically: covers devices paired while
        // the app runs and Bluetooth access being granted after launch.
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, started else { return }
                if devices.isEmpty { refresh() }
            }
        }
    }
    func stop() {
        started = false; rescanTask?.cancel(); rescanTask = nil
        connectNotification?.unregister(); connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll(); pending.removeAll(); devices.removeAll(); publish()
    }
    func refresh() {
        guard started else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let addresses = Set(paired.compactMap(\.addressString))
        devices = devices.filter { addresses.contains($0.key) }
        for address in Array(disconnectNotifications.keys) where !addresses.contains(address) {
            disconnectNotifications.removeValue(forKey: address)?.unregister()
        }
        for device in paired {
            guard let address = device.addressString else { continue }
            if disconnectNotifications[address] == nil {
                disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            }
            inspect(device)
            // Cached SDP works for offline devices; refresh SDP asynchronously on every
            // paired device so names never stand in for the advertised service UUID.
            guard !pending.contains(address) else { continue }
            pending.insert(address)
            let result = device.performSDPQuery(self, uuids: [Self.controlUUID, Self.fastPairUUID])
            if result != kIOReturnSuccess { pending.remove(address) }
            else {
                timeouts[address] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    pending.remove(address); timeouts.removeValue(forKey: address); publish()
                }
            }
        }
        publish()
    }
    private func inspect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        var control: BluetoothRFCOMMChannelID = 0
        guard let service = device.getServiceRecord(for: Self.controlUUID), service.getRFCOMMChannelID(&control) == kIOReturnSuccess else {
            if let name = device.name, name.localizedCaseInsensitiveContains("nothing") || name.localizedCaseInsensitiveContains("cmf") {
                let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
                let rfcommCount = records.filter { record in
                    var channel: BluetoothRFCOMMChannelID = 0
                    return record.getRFCOMMChannelID(&channel) == kIOReturnSuccess
                }.count
                Self.log.info("Paired audio candidate has no Nothing control record; connected=\(device.isConnected()); SDP records=\(records.count), RFCOMM records=\(rfcommCount)")
            }
            return
        }
        var fastPair: BluetoothRFCOMMChannelID = 0
        let record = device.getServiceRecord(for: Self.fastPairUUID)
        let hasFastPair = record?.getRFCOMMChannelID(&fastPair) == kIOReturnSuccess
        devices[address] = PairedAudioDevice(id: address, name: device.name ?? "Nothing / CMF device", connected: device.isConnected(), controlChannel: control, fastPairChannel: hasFastPair ? fastPair : nil)
    }
    private func publish() { onDevices?(devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, !pending.isEmpty) }
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let address = device?.addressString else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, started else { return }
            timeouts.removeValue(forKey: address)?.cancel(); pending.remove(address)
            if status == kIOReturnSuccess, let device = IOBluetoothDevice(addressString: address) { inspect(device) }
            publish()
        }
    }
    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification!, device: IOBluetoothDevice!) {
        guard let address = device?.addressString else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, started else { return }
            onConnection?(address, true); refresh()
        }
    }
    @objc nonisolated private func disconnected(_ notification: IOBluetoothUserNotification!, device: IOBluetoothDevice!) {
        guard let address = device?.addressString else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, started else { return }
            if let device = IOBluetoothDevice(addressString: address) { inspect(device) }
            publish(); onConnection?(address, false)
        }
    }
}
