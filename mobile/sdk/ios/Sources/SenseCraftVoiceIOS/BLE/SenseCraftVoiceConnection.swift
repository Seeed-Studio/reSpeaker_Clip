import Foundation
import CoreBluetooth

@MainActor
public final class SenseCraftVoiceConnection {
    public let peripheral: CBPeripheral
    public let commandRx: CBCharacteristic
    public let responseTx: CBCharacteristic
    public let fileData: CBCharacteristic
    public let mtu: MtuManager
    public let batteryCharacteristic: CBCharacteristic?

    private let responseHub = BroadcastHub<Data>()
    private let fileDataHub = BroadcastHub<Data>()
    private let batteryHub = BroadcastHub<Int>()
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var isInvalidated = false

    init(
        peripheral: CBPeripheral,
        commandRx: CBCharacteristic,
        responseTx: CBCharacteristic,
        fileData: CBCharacteristic,
        batteryCharacteristic: CBCharacteristic?
    ) {
        self.peripheral = peripheral
        self.commandRx = commandRx
        self.responseTx = responseTx
        self.fileData = fileData
        self.batteryCharacteristic = batteryCharacteristic
        self.mtu = MtuManager(peripheral: peripheral)
    }

    public func responseNotifyBytes() -> AsyncStream<Data> {
        responseHub.stream()
    }

    public func fileDataNotifyBytes() -> AsyncStream<Data> {
        fileDataHub.stream()
    }

    public func batteryLevelStream() -> AsyncStream<Int>? {
        batteryCharacteristic == nil ? nil : batteryHub.stream()
    }

    func publishResponse(_ data: Data) {
        responseHub.publish(data)
    }

    func publishFileData(_ data: Data) {
        fileDataHub.publish(data)
    }

    func publishBattery(_ value: Int) {
        batteryHub.publish(value)
    }

    func finishStreams() {
        guard !isInvalidated else { return }
        isInvalidated = true
        responseHub.finish()
        fileDataHub.finish()
        batteryHub.finish()
    }

    func resumePendingWrite(error: Error? = nil) {
        guard let pendingWrite else { return }
        self.pendingWrite = nil
        if let error {
            pendingWrite.resume(throwing: error)
        } else {
            pendingWrite.resume()
        }
    }

    func writeCommand(
        _ command: String,
        withoutResponse: Bool = false,
        interChunkDelay: TimeInterval = 0.016
    ) async throws {
        let payload = Data(command.utf8)
        let type = try commandWriteType(preferWithoutResponse: withoutResponse)
        let limit = max(1, peripheral.maximumWriteValueLength(for: type))
        let chunks = payload.chunked(by: limit)

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            try await write(chunk, type: type)
            if type == .withoutResponse, index + 1 < chunks.count, interChunkDelay > 0 {
                let nanos = UInt64(interChunkDelay * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func commandWriteType(preferWithoutResponse: Bool) throws -> CBCharacteristicWriteType {
        let properties = commandRx.properties
        if preferWithoutResponse, properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if properties.contains(.write) {
            return .withResponse
        }
        if properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        throw SenseCraftVoiceError.missingCharacteristic(
            "Command characteristic \(commandRx.uuid.uuidString) is not writable. Properties: \(Self.describe(properties))"
        )
    }

    private func write(_ data: Data, type: CBCharacteristicWriteType) async throws {
        if type == .withoutResponse {
            peripheral.writeValue(data, for: commandRx, type: type)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingWrite = continuation
            peripheral.writeValue(data, for: commandRx, type: type)
        }
    }

    public static func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }
}

private extension Data {
    func chunked(by limit: Int) -> [Data] {
        guard !isEmpty else { return [] }
        if count <= limit { return [self] }
        var out: [Data] = []
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: limit, limitedBy: endIndex) ?? endIndex
            out.append(subdata(in: idx..<next))
            idx = next
        }
        return out
    }
}
