import Foundation
import CoreBluetooth

@MainActor
public struct ScanResult: Identifiable {
    public let id: UUID
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int
    public let advertisementData: [String: Any]
    public let isConnectable: Bool

    public init(
        peripheral: CBPeripheral,
        name: String,
        rssi: Int,
        advertisementData: [String: Any],
        isConnectable: Bool
    ) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.name = name
        self.rssi = rssi
        self.advertisementData = advertisementData
        self.isConnectable = isConnectable
    }
}

@MainActor
public final class SenseCraftVoiceClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public var scanResults: AsyncStream<[ScanResult]> { scanResultsHub.stream() }
    public var isScanning: AsyncStream<Bool> { scanningHub.stream() }
    public var adapterState: AsyncStream<CBManagerState> { stateHub.stream() }
    public var currentAdapterState: CBManagerState { central.state }

    private let central: CBCentralManager
    private let scanResultsHub = BroadcastHub<[ScanResult]>()
    private let scanningHub = BroadcastHub<Bool>()
    private let stateHub = BroadcastHub<CBManagerState>()
    private var scanTimer: Task<Void, Never>?

    private final class PeripheralSession {
        let peripheral: CBPeripheral
        var connection: SenseCraftVoiceConnection?
        var connectContinuation: CheckedContinuation<SenseCraftVoiceConnection, Error>?
        var connectTimeoutTask: Task<Void, Never>?
        var disconnectContinuation: CheckedContinuation<Void, Never>?
        var disconnectTimeoutTask: Task<Void, Never>?
        var commandCharacteristic: CBCharacteristic?
        var responseCharacteristic: CBCharacteristic?
        var fileDataCharacteristic: CBCharacteristic?
        var batteryCharacteristic: CBCharacteristic?
        var notifiedCharacteristics = Set<CBUUID>()

        init(peripheral: CBPeripheral) {
            self.peripheral = peripheral
        }
    }

    private var peripherals: [UUID: PeripheralSession] = [:]
    private var scanCache: [UUID: ScanResult] = [:]
    private var scanFiltersByName = true

    public override init() {
        self.central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
        stateHub.publish(central.state)
    }

    /// Scans for Clip devices. By default, results are matched by the "Clip"
    /// name because some firmware does not advertise the custom service UUID.
    public func startScan(
        timeout: TimeInterval = 12,
        filterByService: Bool = false
    ) async throws {
        guard central.state == .poweredOn else {
            throw bluetoothStateError()
        }
        stopScan()
        scanCache.removeAll()
        scanResultsHub.publish([])
        scanningHub.publish(true)
        scanFiltersByName = !filterByService

        if filterByService {
            central.scanForPeripherals(
                withServices: [SenseCraftVoiceBleUuids.clipAtService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else {
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }

        if timeout > 0 {
            scanTimer?.cancel()
            scanTimer = Task { [weak self] in
                let nanos = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    self?.stopScan()
                }
            }
        }
    }

    public func stopScan() {
        scanTimer?.cancel()
        scanTimer = nil
        central.stopScan()
        scanningHub.publish(false)
    }

    public func connect(_ result: ScanResult, timeout: TimeInterval = 15) async throws -> SenseCraftVoiceConnection {
        try await connect(peripheral: result.peripheral, timeout: timeout)
    }

    public func connect(by identifier: UUID, timeout: TimeInterval = 15) async throws -> SenseCraftVoiceConnection? {
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return nil
        }
        return try await connect(peripheral: peripheral, timeout: timeout)
    }

    /// Reconnect using CoreBluetooth's stable peripheral identifier without
    /// requiring a new scan. Returns `nil` when iOS no longer knows the
    /// identifier or every connection attempt fails.
    public func connectByDeviceId(
        _ deviceId: String,
        timeout: TimeInterval = 8,
        attempts: Int = 1,
        retryGap: TimeInterval = 0.45
    ) async -> SenseCraftVoiceConnection? {
        guard let identifier = UUID(uuidString: deviceId.trimmingCharacters(in: .whitespacesAndNewlines)),
              let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            SdkLog.w("SenseCraftVoiceClient.connectByDeviceId: unknown iOS peripheral id \(deviceId)")
            return nil
        }

        let attemptCount = max(1, attempts)
        for attempt in 0..<attemptCount {
            do {
                return try await connect(peripheral: peripheral, timeout: timeout)
            } catch {
                SdkLog.w(
                    "SenseCraftVoiceClient.connectByDeviceId attempt \(attempt + 1)/\(attemptCount) failed",
                    error
                )
                if attempt + 1 < attemptCount, retryGap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(retryGap * 1_000_000_000))
                }
            }
        }
        return nil
    }

    /// Direct reconnect followed by an `AT+GSTAT` readiness probe.
    public func connectByDeviceIdAndVerify(
        _ deviceId: String,
        connectTimeout: TimeInterval = 8,
        connectAttempts: Int = 1,
        policy: LinkReadyRetryPolicy = LinkReadyRetryPolicy()
    ) async -> SenseCraftVoiceConnection? {
        guard let connection = await connectByDeviceId(
            deviceId,
            timeout: connectTimeout,
            attempts: connectAttempts,
            retryGap: policy.retryGap
        ) else {
            return nil
        }
        guard await verifyAtLinkReadyWithRetry(connection, policy: policy) else {
            await disconnect(connection)
            return nil
        }
        return connection
    }

    /// Connect a scan result and only return it after the AT channel responds.
    public func connectAndVerify(
        _ result: ScanResult,
        connectTimeout: TimeInterval = 15,
        policy: LinkReadyRetryPolicy = LinkReadyRetryPolicy()
    ) async throws -> SenseCraftVoiceConnection? {
        let connection = try await connect(result, timeout: connectTimeout)
        guard await verifyAtLinkReadyWithRetry(connection, policy: policy) else {
            await disconnect(connection)
            return nil
        }
        return connection
    }

    /// Confirm that the live GATT link can exchange AT JSON messages.
    public func verifyAtLinkReady(
        _ connection: SenseCraftVoiceConnection,
        timeout: TimeInterval = 4
    ) async -> Bool {
        do {
            let response = try await AtTransport(connection: connection).send(
                "AT+GSTAT",
                timeout: max(0.1, timeout)
            )
            let ready = LinkReadyVerification.responseIsReady(response)
            if !ready {
                SdkLog.w("SenseCraftVoiceClient.verifyAtLinkReady: AT+GSTAT ok=false")
            }
            return ready
        } catch {
            SdkLog.w("SenseCraftVoiceClient.verifyAtLinkReady: AT+GSTAT failed", error)
            return false
        }
    }

    /// Retry the readiness probe to absorb notification/subscription settling
    /// immediately after CoreBluetooth reports the link connected.
    public func verifyAtLinkReadyWithRetry(
        _ connection: SenseCraftVoiceConnection,
        policy: LinkReadyRetryPolicy = LinkReadyRetryPolicy()
    ) async -> Bool {
        await LinkReadyVerification.run(policy: policy) { timeout in
            await self.verifyAtLinkReady(connection, timeout: timeout)
        }
    }

    public func disconnect(_ connection: SenseCraftVoiceConnection) async {
        await withCheckedContinuation { continuation in
            let session = peripherals[connection.peripheral.identifier] ?? PeripheralSession(peripheral: connection.peripheral)
            guard connection.peripheral.state != .disconnected else {
                session.connection?.finishStreams()
                peripherals.removeValue(forKey: connection.peripheral.identifier)
                continuation.resume()
                return
            }
            session.disconnectContinuation = continuation
            peripherals[connection.peripheral.identifier] = session
            session.disconnectTimeoutTask?.cancel()
            session.disconnectTimeoutTask = Task { [weak self, weak peripheral = connection.peripheral] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    guard let self, let peripheral else { return }
                    self.finishDisconnect(peripheral)
                }
            }
            central.cancelPeripheralConnection(connection.peripheral)
        }
    }

    private func connect(peripheral: CBPeripheral, timeout: TimeInterval) async throws -> SenseCraftVoiceConnection {
        if let existing = peripherals[peripheral.identifier]?.connection {
            return existing
        }
        let session = peripherals[peripheral.identifier] ?? PeripheralSession(peripheral: peripheral)
        peripherals[peripheral.identifier] = session
        peripheral.delegate = self
        session.peripheral.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            session.connectContinuation = continuation
            session.connectTimeoutTask?.cancel()
            session.connectTimeoutTask = Task { [weak self, weak peripheral] in
                let nanos = UInt64(max(0.1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self, let peripheral else { return }
                    guard self.peripherals[peripheral.identifier]?.connectContinuation != nil else { return }
                    self.central.cancelPeripheralConnection(peripheral)
                    self.sessionFinish(
                        peripheral,
                        error: SenseCraftVoiceError.timeout("BLE connect timeout for \(peripheral.identifier.uuidString)")
                    )
                }
            }
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateHub.publish(central.state)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown"
        if scanFiltersByName,
           !name.localizedCaseInsensitiveContains("Clip") {
            return
        }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        let result = ScanResult(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            advertisementData: advertisementData,
            isConnectable: connectable
        )
        scanCache[peripheral.identifier] = result
        scanResultsHub.publish(scanCache.values.sorted { $0.rssi > $1.rssi })
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = peripherals[peripheral.identifier] else { return }
        peripheral.delegate = self
        session.peripheral.delegate = self
        session.peripheral.discoverServices([
            SenseCraftVoiceBleUuids.clipAtService,
            SenseCraftVoiceBleUuids.batteryService,
            SenseCraftVoiceBleUuids.smpService,
        ])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard let session = peripherals[peripheral.identifier] else { return }
        session.connection?.finishStreams()
        session.connectTimeoutTask?.cancel()
        session.connectTimeoutTask = nil
        session.connectContinuation?.resume(throwing: error ?? SenseCraftVoiceError.connectionFailed(peripheral.identifier.uuidString))
        session.connectContinuation = nil
        peripherals.removeValue(forKey: peripheral.identifier)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard let session = peripherals[peripheral.identifier] else { return }
        session.connection?.finishStreams()
        if let error {
            SdkLog.w("Peripheral disconnected: \(error)")
        }
        finishDisconnect(peripheral)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: (any Error)?
    ) {
        guard error == nil, peripherals[peripheral.identifier] != nil else {
            sessionFinish(peripheral, error: error)
            return
        }
        guard let services = peripheral.services else {
            sessionFinish(peripheral, error: SenseCraftVoiceError.invalidResponse("missing services"))
            return
        }
        guard services.contains(where: { $0.uuid == SenseCraftVoiceBleUuids.clipAtService }) else {
            let found = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            sessionFinish(
                peripheral,
                error: SenseCraftVoiceError.missingCharacteristic("Clip AT service missing. Found services: \(found)")
            )
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard error == nil, let session = peripherals[peripheral.identifier] else {
            sessionFinish(peripheral, error: error)
            return
        }
        guard let chars = service.characteristics else { return }

        for char in chars {
            switch char.uuid {
            case SenseCraftVoiceBleUuids.commandRxCharacteristic:
                session.commandCharacteristic = char
            case SenseCraftVoiceBleUuids.responseTxCharacteristic:
                session.responseCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            case SenseCraftVoiceBleUuids.fileDataCharacteristic:
                session.fileDataCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            case SenseCraftVoiceBleUuids.batteryLevelCharacteristic:
                session.batteryCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }

        if service.uuid == SenseCraftVoiceBleUuids.clipAtService,
           session.commandCharacteristic == nil ||
           session.responseCharacteristic == nil ||
           session.fileDataCharacteristic == nil {
            let found = chars.map { $0.uuid.uuidString }.joined(separator: ", ")
            sessionFinish(
                peripheral,
                error: SenseCraftVoiceError.missingCharacteristic("Clip AT characteristics missing. Found: \(found)")
            )
            return
        }

        if session.connection == nil,
           let command = session.commandCharacteristic,
           let response = session.responseCharacteristic,
           let fileData = session.fileDataCharacteristic {
            session.connection = SenseCraftVoiceConnection(
                peripheral: peripheral,
                commandRx: command,
                responseTx: response,
                fileData: fileData,
                batteryCharacteristic: session.batteryCharacteristic
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let session = peripherals[peripheral.identifier] else { return }
        guard let connection = session.connection else { return }
        if characteristic.isNotifying {
            session.notifiedCharacteristics.insert(characteristic.uuid)
        }
        let required: Set<CBUUID> = [
            SenseCraftVoiceBleUuids.responseTxCharacteristic,
            SenseCraftVoiceBleUuids.fileDataCharacteristic,
        ]
        guard required.isSubset(of: session.notifiedCharacteristics) else { return }
        if let continuation = session.connectContinuation {
            session.connectContinuation = nil
            session.connectTimeoutTask?.cancel()
            session.connectTimeoutTask = nil
            continuation.resume(returning: connection)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil, let session = peripherals[peripheral.identifier] else { return }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case SenseCraftVoiceBleUuids.responseTxCharacteristic:
            session.connection?.publishResponse(data)
        case SenseCraftVoiceBleUuids.fileDataCharacteristic:
            session.connection?.publishFileData(data)
        case SenseCraftVoiceBleUuids.batteryLevelCharacteristic:
            session.connection?.publishBattery(Int(data.first ?? 0))
        default:
            break
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let session = peripherals[peripheral.identifier] else { return }
        if let error {
            session.connection?.resumePendingWrite(error: error)
        } else {
            session.connection?.resumePendingWrite()
        }
    }

    private func bluetoothStateError() -> Error {
        switch central.state {
        case .poweredOff:
            return SenseCraftVoiceError.bluetoothUnavailable("Bluetooth is off")
        case .unauthorized:
            return SenseCraftVoiceError.bluetoothUnauthorized
        case .unsupported:
            return SenseCraftVoiceError.bluetoothUnavailable("Bluetooth unsupported")
        case .resetting:
            return SenseCraftVoiceError.bluetoothUnavailable("Bluetooth resetting")
        case .unknown:
            return SenseCraftVoiceError.bluetoothUnavailable("Bluetooth state unknown")
        case .poweredOn:
            return SenseCraftVoiceError.internalError("unexpected state")
        @unknown default:
            return SenseCraftVoiceError.bluetoothUnavailable("Bluetooth unavailable")
        }
    }

    private func sessionFinish(_ peripheral: CBPeripheral, error: (any Error)?) {
        guard let session = peripherals[peripheral.identifier] else { return }
        session.connectTimeoutTask?.cancel()
        session.connectTimeoutTask = nil
        session.disconnectTimeoutTask?.cancel()
        session.disconnectTimeoutTask = nil
        if let error {
            session.connectContinuation?.resume(throwing: error)
        } else {
            session.connectContinuation?.resume(throwing: SenseCraftVoiceError.invalidResponse("discovery failed"))
        }
        session.connectContinuation = nil
        session.connection?.finishStreams()
        peripherals.removeValue(forKey: peripheral.identifier)
    }

    private func finishDisconnect(_ peripheral: CBPeripheral) {
        guard let session = peripherals[peripheral.identifier] else { return }
        session.connection?.finishStreams()
        session.connectTimeoutTask?.cancel()
        session.connectTimeoutTask = nil
        session.disconnectTimeoutTask?.cancel()
        session.disconnectTimeoutTask = nil
        if let connectContinuation = session.connectContinuation {
            session.connectContinuation = nil
            connectContinuation.resume(throwing: SenseCraftVoiceError.connectionFailed("Peripheral disconnected during connect: \(peripheral.identifier.uuidString)"))
        }
        session.disconnectContinuation?.resume()
        session.disconnectContinuation = nil
        peripherals.removeValue(forKey: peripheral.identifier)
    }
}
