import Foundation
@preconcurrency import IOBluetooth

struct BluetoothFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// IOBluetooth is run-loop based. The main actor owns channels, continuations, and
/// the write FIFO. ObjC callbacks copy pointer data before hopping to that actor.
/// No synchronous connect/write call blocks the UI. Only one async write is in flight.
@MainActor
final class RFCOMMTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void, any Error>?
    private struct Write {
        let bytes: [UInt8]
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var writes: [Write] = []
    private var activeBuffer: NSMutableData?
    private var offset = 0
    private var timeout: Task<Void, Never>?
    var onData: (([UInt8]) -> Void)?
    var onFailure: ((any Error) -> Void)?
    var onClosed: (() -> Void)?
    var isOpen: Bool { channel?.isOpen() == true && opening == nil }

    func open(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) async throws {
        close()
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation
            var opened: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            channel = opened
            guard status == kIOReturnSuccess, opened != nil else {
                fail(BluetoothFailure(message: "Could not open RFCOMM (\(status)). Connect the device in Bluetooth settings, then retry.")); return
            }
            armTimeout("Bluetooth channel did not open within 12 seconds.")
        }
    }
    func write(_ bytes: [UInt8]) async throws {
        guard isOpen else { throw BluetoothFailure(message: "The control channel is disconnected.") }
        try await withCheckedThrowingContinuation { continuation in
            writes.append(Write(bytes: bytes, continuation: continuation))
            if writes.count == 1 { sendChunk() }
        }
    }
    func close() {
        let old = channel
        channel = nil
        old?.setDelegate(nil)
        old?.close()
        fail(BluetoothFailure(message: "Bluetooth channel closed."))
    }
    private func fail(_ error: any Error) {
        timeout?.cancel(); timeout = nil
        let pendingOpen = opening; opening = nil
        let pendingWrites = writes; writes.removeAll()
        activeBuffer = nil; offset = 0
        pendingOpen?.resume(throwing: error)
        for write in pendingWrites { write.continuation.resume(throwing: error) }
    }
    private func armTimeout(_ message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self else { return }
            timeoutReached(message)
        }
    }
    func timeoutReached(_ message: String) {
        let failure = BluetoothFailure(message: message)
        // Report before onClosed invalidates the session generation and cancels
        // the task waiting on this continuation.
        onFailure?(failure)
        let old = channel; channel = nil
        old?.setDelegate(nil); old?.close()
        fail(failure); onClosed?()
    }
    private func sendChunk() {
        guard let channel, let first = writes.first else { return }
        let count = min(max(1, Int(channel.getMTU())), first.bytes.count - offset)
        guard count > 0 else { finishWrite(); return }
        let data = Data(first.bytes[offset..<(offset + count)])
        let buffer = NSMutableData(data: data)
        activeBuffer = buffer
        armTimeout("Bluetooth write timed out. Reconnect the device.")
        let result = channel.writeAsync(buffer.mutableBytes, length: UInt16(count), refcon: nil)
        if result != kIOReturnSuccess {
            close(); onClosed?()
        }
    }
    private func finishWrite() {
        guard !writes.isEmpty else { return }
        let first = writes.removeFirst(); offset = 0
        first.continuation.resume()
        sendChunk()
    }
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let rfcommChannel else { return }
        let id = ObjectIdentifier(rfcommChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == id, let continuation = opening else { return }
            timeout?.cancel(); timeout = nil; opening = nil
            if error == kIOReturnSuccess { continuation.resume() }
            else { continuation.resume(throwing: BluetoothFailure(message: "RFCOMM open failed (\(error)).")); close() }
        }
    }
    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let rfcommChannel, let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        let id = ObjectIdentifier(rfcommChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == id else { return }
            onData?(bytes)
        }
    }
    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard let rfcommChannel else { return }
        let id = ObjectIdentifier(rfcommChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == id else { return }
            close(); onClosed?()
        }
    }
    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard let rfcommChannel else { return }
        let id = ObjectIdentifier(rfcommChannel)
        DispatchQueue.main.async { [weak self] in
            guard let self, let channel = self.channel, ObjectIdentifier(channel) == id, let buffer = activeBuffer else { return }
            timeout?.cancel(); timeout = nil
            if error != kIOReturnSuccess { close(); onClosed?(); return }
            offset += buffer.length; activeBuffer = nil
            if offset >= (writes.first?.bytes.count ?? 0) { finishWrite() } else { sendChunk() }
        }
    }
}
