import Foundation
import SwiftUI
import CoreBluetooth
import SenseCraftVoiceIOS

@MainActor
final class VerifyViewModel: ObservableObject {
    @Published var adapterState: String = "unknown"
    @Published var scanResults: [ScanResult] = []
    @Published var logs: [String] = []
    @Published var latestLog: String = "Ready."
    @Published var connectedDeviceLabel: String = "not connected"
    @Published var statusLabel: String = "idle"
    @Published var activeSessionId: String = ""
    @Published var wifiSessionId: String = ""
    @Published var wifiProgress: Double = 0
    @Published var wifiProgressText: String = "0%"
    @Published var otaProgress: Double = 0
    @Published var otaProgressText: String = "0%"
    @Published var otaFirmwareURL: URL?
    @Published var otaFileLabel: String = "no firmware selected"
    @Published var deviceNameInput: String = ""
    @Published var deviceNameSummary: String = "not read"
    @Published var deviceTimeSummary: String = "not read"
    @Published var pairingSummary: String = "not read"
    @Published var recordingModeIsEnhanced: Bool = false
    @Published var joinPhoneOnWifi: Bool = true
    @Published var requirePhoneJoin: Bool = false
    @Published var showOnlyProjectDevices: Bool = true
    @Published var filterScanByService: Bool = false
    @Published var discoveredDeviceCount: Int = 0
    @Published var manualPeripheralId: String = ""
    @Published var downloadStartFile: String = ""
    @Published var downloadSessionId: String = ""
    @Published var runtimeSummary: String = "not read"
    @Published var filesSummary: String = "not listed"
    @Published var isScanning: Bool = false
    @Published var isBusy: Bool = false
    @Published var isConnected: Bool = false

    private let client = SenseCraftVoiceClient()
    private var connection: SenseCraftVoiceConnection?
    private var at: AtTransport?
    private var recordingSession: RecordingSession?
    private var wifiSession: WifiFastSyncSession?
    private var otaSession: OtaSession?
    private var scanObserverTask: Task<Void, Never>?
    private var adapterObserverTask: Task<Void, Never>?
    private var scanningObserverTask: Task<Void, Never>?
    private var scanFallbackTask: Task<Void, Never>?
    private var deviceEventTask: Task<Void, Never>?
    private var otaEventTask: Task<Void, Never>?
    private var latestRawScanResults: [ScanResult] = []

    init() {
        SdkLog.bind { [weak self] level, message, error, _ in
            Task { @MainActor in
                let suffix = error.map { " \($0)" } ?? ""
                self?.log("SDK \(level.rawValue): \(message)\(suffix)")
            }
        }
        bindClientStreams()
        Task {
            _ = await SenseCraftVoiceBlePermissions.ensureGranted()
            log("SDK ready.")
        }
    }

    deinit {
        scanObserverTask?.cancel()
        adapterObserverTask?.cancel()
        scanningObserverTask?.cancel()
        scanFallbackTask?.cancel()
        deviceEventTask?.cancel()
        otaEventTask?.cancel()
    }

    func localSmoke() {
        log("Running local smoke checks...")

        let framer = JsonObjectFramer()
        let pieces = framer.feed("{\"ok\":") + framer.feed("true}")
        guard pieces.count == 1 else {
            log("FAIL: JsonObjectFramer smoke")
            return
        }

        let ratio = TransferProgress.wifiAligned(
            framedMode: true,
            currentFileDeclaredSize: 100,
            bytesThisFile: 40,
            receivedSession: 240,
            expectedSession: 1000,
            filesCompleted: 2,
            deviceTotalFiles: 5,
            deviceSessionBytes: 1000
        )
        guard abs((ratio ?? -1) - 0.24) < 0.0001 else {
            log("FAIL: TransferProgress smoke")
            return
        }

        let state = BleTransferFrameState()
        let name = Array("0001.opus".utf8)
        var frame = Data([kClipFrameFileStart, UInt8(name.count)])
        frame.append(contentsOf: name)
        frame.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
        guard case .fileStart(let filename, let size) = BleTransferFrameHandler.handle(bytes: frame, state: state),
              filename == "0001.opus",
              size == 3 else {
            log("FAIL: BleTransferFrameHandler smoke")
            return
        }

        log("PASS: local SDK smoke checks passed.")
    }

    func startScan() {
        Task {
            guard !isBusy else {
                log("Busy. Wait for the current action to finish.")
                return
            }
            isBusy = true
            defer { isBusy = false }
            do {
                _ = await SenseCraftVoiceBlePermissions.ensureGranted()
                adapterState = describe(client.currentAdapterState)
                guard await waitForBluetoothReady(timeout: 8) else {
                    statusLabel = "Bluetooth \(adapterState)"
                    log("Scan not started: Bluetooth adapter is \(adapterState). Check iOS Bluetooth permission and make sure Bluetooth is on.")
                    return
                }
                scanResults = []
                latestRawScanResults = []
                discoveredDeviceCount = 0
                statusLabel = "scanning"
                let shouldFilter = filterScanByService
                log(shouldFilter ? "Scanning by Clip service UUID for 12 seconds..." : "Scanning nearby BLE devices; showing Clip devices only...")
                try await client.startScan(timeout: 12, filterByService: shouldFilter)
                isScanning = true
                scheduleScanFallbackIfNeeded(startedWithServiceFilter: shouldFilter)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) { [weak self] in
                    self?.stopScan()
                }
            } catch {
                statusLabel = "scan failed"
                log("Scan failed: \(error)")
                isScanning = false
            }
        }
    }

    func stopScan() {
        Task {
            scanFallbackTask?.cancel()
            scanFallbackTask = nil
            client.stopScan()
            isScanning = false
            if statusLabel == "scanning" {
                statusLabel = "scan stopped"
            }
            log("Scan stopped.")
        }
    }

    func describeScanResult(_ result: ScanResult) -> String {
        var parts = ["RSSI \(result.rssi)"]
        parts.append(result.isConnectable ? "connectable" : "not connectable")

        if let localName = result.advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           !localName.isEmpty,
           localName != result.name {
            parts.append("advName \(localName)")
        }

        if let services = result.advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           !services.isEmpty {
            let text = services.map { $0.uuidString }.joined(separator: ",")
            parts.append("services \(text)")
        } else {
            parts.append("services none")
        }

        return parts.joined(separator: "  ")
    }

    func applyProjectDeviceFilter() {
        scanResults = filterScanResults(latestRawScanResults)
    }

    func connect(_ result: ScanResult) {
        Task {
            guard !isBusy else {
                log("Busy. Wait for the current action to finish.")
                return
            }
            isBusy = true
            defer { isBusy = false }
            do {
                scanFallbackTask?.cancel()
                scanFallbackTask = nil
                client.stopScan()
                isScanning = false
                statusLabel = "connecting"
                log("Connecting to \(displayName(result)) \(result.id.uuidString)...")
                if !result.isConnectable {
                    log("Warning: advertisement says this device is not connectable; trying anyway.")
                }
                let conn = try await client.connect(result, timeout: 15)
                try await verifyAndAttachConnection(conn, displayName: displayName(result), identifier: result.id.uuidString)
            } catch {
                statusLabel = "connect failed"
                log("Connect failed: \(error). If this is iOS and the device was paired before, open iOS Settings > Bluetooth, forget the Clip device, then scan and connect again.")
            }
        }
    }

    private func scheduleScanFallbackIfNeeded(startedWithServiceFilter: Bool) {
        scanFallbackTask?.cancel()
        guard startedWithServiceFilter else { return }
        scanFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run {
                guard let self, self.isScanning, self.scanResults.isEmpty else { return }
                self.log("No devices found with service filter. Retrying with all BLE devices...")
                self.filterScanByService = false
                self.scanResults = []
                self.client.stopScan()
                Task { @MainActor in
                    do {
                        try await self.client.startScan(timeout: 8, filterByService: false)
                    } catch {
                        self.statusLabel = "scan failed"
                        self.log("Fallback scan failed: \(error)")
                    }
                }
            }
        }
    }

    private func filterScanResults(_ results: [ScanResult]) -> [ScanResult] {
        guard showOnlyProjectDevices else { return results }
        return results.filter(isProjectDevice)
    }

    private func isProjectDevice(_ result: ScanResult) -> Bool {
        effectiveDeviceName(result).lowercased().contains("clip")
    }

    private func effectiveDeviceName(_ result: ScanResult) -> String {
        let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name.lowercased() != "unknown" {
            return name
        }
        if let advName = result.advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            return advName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func displayName(_ result: ScanResult) -> String {
        let name = effectiveDeviceName(result)
        return name.isEmpty ? "Unknown" : name
    }

    func connectByEnteredId() {
        Task {
            guard !isBusy else {
                log("Busy. Wait for the current action to finish.")
                return
            }
            isBusy = true
            defer { isBusy = false }
            let input = scanResults.first(where: { $0.id.uuidString.lowercased() == manualPeripheralId.lowercased() })
            if let input {
                do {
                    scanFallbackTask?.cancel()
                    scanFallbackTask = nil
                    client.stopScan()
                    isScanning = false
                    statusLabel = "connecting"
                    log("Connecting to \(displayName(input)) \(input.id.uuidString)...")
                    let conn = try await client.connect(input, timeout: 15)
                    try await verifyAndAttachConnection(conn, displayName: displayName(input), identifier: input.id.uuidString)
                } catch {
                    statusLabel = "connect failed"
                    log("Connect failed: \(error). If this is iOS and the device was paired before, open iOS Settings > Bluetooth, forget the Clip device, then scan and connect again.")
                }
            } else {
                log("No scan result matched the entered UUID.")
            }
        }
    }

    func disconnect() {
        Task {
            guard let connection else {
                if statusLabel == "connecting" {
                    log("Connect is still in progress. Wait for the connect timeout, then retry scan/connect.")
                } else {
                    log("Already disconnected.")
                }
                return
            }
            statusLabel = "disconnecting"
            log("Disconnecting \(connection.peripheral.identifier.uuidString)...")
            await client.disconnect(connection)
            detachConnection()
            log("Disconnected.")
        }
    }

    func refreshStatus() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then retry Status.")
                return
            }
            do {
                let status = try await recordingSession.getStatus()
                statusLabel = describe(status)
                log("AT+GSTAT -> \(describe(status))")
            } catch {
                log("Status failed: \(error)")
            }
        }
    }

    func readRuntimeInfo() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then read runtime info.")
                return
            }
            runtimeSummary = "reading"
            let info = await recordingSession.readRuntimeInfo()
            runtimeSummary = describe(info)
            if let time = info.formattedDeviceTime {
                deviceTimeSummary = time
            }
            if let pair = info.pairStatus {
                pairingSummary = info.pairAddress.map { "\(pair) \($0)" } ?? pair
            }
            if info.hasAnyData {
                log("Runtime -> \(describe(info))")
            } else {
                log("Runtime read completed, but the device returned no recognized fields.")
            }
        }
    }

    func syncDeviceTime() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then sync time.")
                return
            }
            log("Syncing device time...")
            let changed = await recordingSession.syncDeviceTime(force: true)
            log(changed ? "Device time synced." : "Device time sync skipped or failed.")
            readRuntimeInfo()
        }
    }

    func readDeviceTime() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then read device time.")
                return
            }
            do {
                let info = try await recordingSession.getDeviceTime()
                deviceTimeSummary = describe(info)
                log("Device time -> \(describe(info))")
            } catch {
                log("Read device time failed: \(error)")
            }
        }
    }

    func readPairingStatus() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then read pairing status.")
                return
            }
            do {
                let info = try await recordingSession.getPairingStatus()
                pairingSummary = describe(info)
                log("Pairing -> \(describe(info))")
            } catch {
                log("Read pairing status failed: \(error)")
            }
        }
    }

    func pauseRecording() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then pause.")
                return
            }
            do {
                let info = try await recordingSession.pause()
                if let sessionId = info.sessionId, !sessionId.isEmpty {
                    activeSessionId = sessionId
                    downloadSessionId = sessionId
                }
                log("Pause -> session=\(info.sessionId ?? "-") duration=\(info.durationSeconds ?? -1)")
            } catch {
                log("Pause failed: \(error)")
            }
        }
    }

    func resumeRecording() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then resume.")
                return
            }
            do {
                let info = try await recordingSession.resume()
                if let sessionId = info.sessionId, !sessionId.isEmpty {
                    activeSessionId = sessionId
                    downloadSessionId = sessionId
                }
                log("Resume -> session=\(info.sessionId ?? "-") duration=\(info.durationSeconds ?? -1)")
            } catch {
                log("Resume failed: \(error)")
            }
        }
    }

    func applyRecordingMode() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then set mode.")
                return
            }
            do {
                let mode: RecordingMode = recordingModeIsEnhanced ? .enhanced : .normal
                let applied = try await recordingSession.setRecordingMode(mode)
                recordingModeIsEnhanced = applied == .enhanced
                log("Mode -> \(applied.rawValue)")
            } catch {
                log("Set mode failed: \(error)")
            }
        }
    }

    func markBookmark() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then mark.")
                return
            }
            do {
                let result = try await recordingSession.mark()
                if let sessionId = result.sessionId, !sessionId.isEmpty {
                    downloadSessionId = sessionId
                }
                log("Mark -> ok=\(result.ok) session=\(result.sessionId ?? "-") count=\(result.markCount ?? -1) offset=\(result.offsetSeconds ?? -1)")
            } catch {
                log("Mark failed: \(error)")
            }
        }
    }

    func readUserDeviceName() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then read device name.")
                return
            }
            do {
                let name = try await recordingSession.getUserDeviceName()
                deviceNameInput = name
                deviceNameSummary = name.isEmpty ? "empty" : name
                log("Device name -> \(name.isEmpty ? "<empty>" : name)")
            } catch {
                log("Read device name failed: \(error)")
            }
        }
    }

    func setUserDeviceName() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then set device name.")
                return
            }
            do {
                let trimmed = deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? nil : trimmed
                try await recordingSession.setUserDeviceName(value)
                deviceNameSummary = trimmed.isEmpty ? "cleared" : trimmed
                if trimmed.isEmpty {
                    deviceNameInput = ""
                }
                log(trimmed.isEmpty ? "Device name cleared." : "Device name set to \(trimmed)")
            } catch {
                log("Set device name failed: \(error)")
            }
        }
    }

    func resetPairing() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then reset pairing.")
                return
            }
            do {
                let resp = try await recordingSession.resetPairing()
                pairingSummary = "reset"
                log("Pairing reset -> \(resp)")
            } catch {
                log("Reset pairing failed: \(error)")
            }
        }
    }

    func listAllFiles() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then list files.")
                return
            }
            do {
                filesSummary = "listing"
                let files = try await recordingSession.listAllFiles(perPage: 10, maxPages: 100)
                filesSummary = describeFileSummary(files)
                if let firstSession = inferSessionId(from: files.first?.path), downloadSessionId.isEmpty {
                    downloadSessionId = firstSession
                }
                log("Files -> \(describeFileSummary(files))")
                files.prefix(8).forEach { log("File \(describe($0))") }
            } catch {
                filesSummary = "failed"
                log("List files failed: \(error)")
            }
        }
    }

    func listBookmarksForEnteredSession() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then list bookmarks.")
                return
            }
            let sessionId = downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else {
                log("Enter a session id first.")
                return
            }
            do {
                let bookmarks = try await recordingSession.listBookmarks(sessionId: sessionId, perPage: 10)
                log("Bookmarks \(sessionId) -> \(bookmarks.count)")
                bookmarks.prefix(8).forEach {
                    log("Bookmark session=\($0.sessionId ?? "-") count=\($0.markCount ?? -1) offset=\($0.offsetSeconds ?? -1) note=\($0.note ?? "-")")
                }
            } catch {
                log("List bookmarks failed: \(error)")
            }
        }
    }

    func startRecording() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then start recording.")
                return
            }
            do {
                let mode: RecordingMode = recordingModeIsEnhanced ? .enhanced : .normal
                let info = try await recordingSession.start(mode: mode)
                activeSessionId = info.sessionId
                downloadSessionId = info.sessionId
                log("Recording started: \(info.sessionId)")
            } catch {
                log("Start failed: \(error)")
            }
        }
    }

    func stopRecording() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then stop recording.")
                return
            }
            do {
                let info = try await recordingSession.stop()
                activeSessionId = info.sessionId ?? ""
                downloadSessionId = info.sessionId ?? downloadSessionId
                log("Recording stopped: \(info)")
            } catch {
                log("Stop failed: \(error)")
            }
        }
    }

    func prepareWifi() {
        Task {
            guard let at else {
                statusLabel = "not connected"
                log("Wi-Fi Prepare needs BLE first: Scan -> tap Clip device -> wait for State = connected -> Prepare.")
                return
            }
            do {
                let session = wifiSession ?? WifiFastSyncSession(at: at)
                wifiSession = session
                wifiProgressText = "preparing"
                log("Preparing device Wi-Fi AP over BLE...")
                let info = try await session.prepare(joinPhone: joinPhoneOnWifi, requirePhoneJoin: requirePhoneJoin)
                wifiSessionId = info.ssid
                wifiProgressText = "ready"
                log("Wi-Fi ready: \(info.ssid) \(info.ip):\(info.port)")
            } catch {
                wifiProgressText = "failed"
                log("Wi-Fi prepare failed: \(error). Make sure BLE is connected and the iOS target has Hotspot Configuration capability for auto-join.")
            }
        }
    }

    func pingWifi() {
        Task {
            guard let wifiSession else {
                log("Prepare Wi-Fi first.")
                return
            }
            let result = await wifiSession.transferClient?.pingDetailed()
            if let result {
                wifiProgressText = result.ok ? "pong" : (result.networkUnreachable ? "unreachable" : "failed")
                log("Wi-Fi ping -> \(result)")
            } else {
                log("Wi-Fi transfer client unavailable.")
            }
        }
    }

    func downloadSession() {
        Task {
            guard let at else {
                log("Connect a Clip device with BLE first, then download.")
                return
            }
            guard !downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("Enter a session id first.")
                return
            }
            let session = wifiSession ?? WifiFastSyncSession(at: at)
            wifiSession = session
            let targetDir = documentsDirectory().appendingPathComponent("SenseCraftDownloads/\(downloadSessionId)", isDirectory: true)
            do {
                log("Downloading \(downloadSessionId) -> \(targetDir.path)")
                let bytes = try await session.downloadSession(
                    sessionId: downloadSessionId,
                    sessionDirectory: targetDir,
                    startFile: downloadStartFile.isEmpty ? nil : downloadStartFile,
                    joinPhone: joinPhoneOnWifi,
                    requirePhoneJoin: requirePhoneJoin,
                    onOverallProgress: { [weak self] value in
                        DispatchQueue.main.async {
                            self?.wifiProgress = value ?? 0
                            self?.wifiProgressText = self?.percentText(value) ?? "0%"
                        }
                    },
                    onProgress: { [weak self] currentFile, filesDone, totalFiles, receivedBytes, totalBytes in
                        DispatchQueue.main.async {
                            self?.log("Download \(currentFile) \(receivedBytes)/\(totalBytes ?? -1) files=\(filesDone)/\(totalFiles)")
                        }
                    }
                )
                log("Download done: \(bytes) bytes")
            } catch {
                log("Download failed: \(error)")
            }
        }
    }

    func bleDownloadMerge() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then BLE download.")
                return
            }
            let sessionId = downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else {
                log("Enter a session id first.")
                return
            }
            let targetDir = documentsDirectory().appendingPathComponent("SenseCraftDownloads/\(sessionId)-ble", isDirectory: true)
            do {
                log("BLE download+merge \(sessionId) -> \(targetDir.path)")
                let result = try await recordingSession.downloadMergeAndMaybeDeleteSession(
                    sessionId: sessionId,
                    directory: targetDir,
                    startFile: downloadStartFile.isEmpty ? nil : downloadStartFile
                )
                log("BLE merge done: files=\(result.download.completedFiles) bytes=\(result.download.completedBytes) merged=\(result.mergedUrl.path) mergedBytes=\(result.mergedBytes)")
            } catch {
                log("BLE merge failed: \(error)")
            }
        }
    }

    func bleDownloadFinalize() {
        Task {
            guard let recordingSession else {
                log("Connect a Clip device with BLE first, then BLE finalize.")
                return
            }
            let sessionId = downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else {
                log("Enter a session id first.")
                return
            }
            let targetDir = documentsDirectory().appendingPathComponent("SenseCraftDownloads/\(sessionId)-finalize", isDirectory: true)
            do {
                log("BLE download+finalize \(sessionId) -> \(targetDir.path)")
                let result = try await recordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession(
                    sessionId: sessionId,
                    directory: targetDir,
                    startFile: downloadStartFile.isEmpty ? nil : downloadStartFile
                )
                log("BLE finalize done: files=\(result.merge.download.completedFiles) merged=\(result.merge.mergedUrl.path) bookmarks=\(result.bookmarks.count) saved=\(result.bookmarksSaved)")
            } catch {
                log("BLE finalize failed: \(error)")
            }
        }
    }

    func pickFirmware(url: URL) {
        do {
            let copied = try copyIntoAppSandbox(url)
            otaFirmwareURL = copied
            otaFileLabel = copied.lastPathComponent
            log("Firmware selected: \(copied.lastPathComponent)")
        } catch {
            log("Firmware copy failed: \(error)")
        }
    }

    func startOta() {
        Task {
            guard let connection else {
                log("Connect a Clip device with BLE first, then start OTA.")
                return
            }
            guard let firmware = otaFirmwareURL else {
                log("Pick a firmware .bin or .zip first.")
                return
            }
            guard !isBusy else { return }
            isBusy = true
            defer { isBusy = false }

            let transport = NordicMcuMgrOtaTransport(peripheral: connection.peripheral)
            let session = OtaSession(
                deviceId: connection.peripheral.identifier.uuidString,
                transport: transport
            )
            otaSession = session
            otaEventTask?.cancel()
            otaEventTask = Task {
                for await progress in session.events {
                    await MainActor.run {
                        self.otaProgress = progress.progress
                        self.otaProgressText = self.percentText(progress.progress)
                    }
                }
            }

            log("Starting OTA with \(firmware.lastPathComponent)")
            let ok = await session.upgrade(firmware)
            log(ok ? "OTA completed." : "OTA failed.")
        }
    }

    private func attachConnection(_ conn: SenseCraftVoiceConnection) {
        let transport = AtTransport(connection: conn)
        connection = conn
        at = transport
        recordingSession = RecordingSession(connection: conn, at: transport)
        wifiSession = WifiFastSyncSession(at: transport)
        connectedDeviceLabel = conn.peripheral.identifier.uuidString
        statusLabel = "connected"
        isConnected = true
        log("BLE characteristics: command=\(describe(conn.commandRx.properties)) response=\(describe(conn.responseTx.properties)) fileData=\(describe(conn.fileData.properties))")
        bindDeviceEvents()
    }

    private func verifyAndAttachConnection(
        _ conn: SenseCraftVoiceConnection,
        displayName: String,
        identifier: String
    ) async throws {
        attachConnection(conn)
        statusLabel = "verifying AT"
        log("GATT connected to \(displayName) \(identifier). Verifying AT+GSTAT...")

        do {
            guard let recordingSession else {
                throw SenseCraftVoiceError.internalError("recording session missing after connect")
            }
            let status = try await recordingSession.getStatus(timeout: 6)
            statusLabel = describe(status)
            log("Connected to \(displayName) \(identifier). AT+GSTAT -> \(describe(status))")
        } catch {
            await client.disconnect(conn)
            detachConnection()
            statusLabel = "connect failed"
            log("GATT connected, but AT+GSTAT did not respond: \(error). On iOS this usually means pairing/bond info is stale or the device has not accepted pairing yet. Forget the Clip in iOS Bluetooth Settings and connect again.")
            throw error
        }
    }

    private func detachConnection() {
        deviceEventTask?.cancel()
        otaEventTask?.cancel()
        connection = nil
        at = nil
        recordingSession = nil
        wifiSession = nil
        connectedDeviceLabel = "not connected"
        statusLabel = "idle"
        activeSessionId = ""
        wifiSessionId = ""
        runtimeSummary = "not read"
        filesSummary = "not listed"
        deviceNameSummary = "not read"
        deviceTimeSummary = "not read"
        pairingSummary = "not read"
        wifiProgress = 0
        wifiProgressText = "0%"
        isConnected = false
    }

    private func bindClientStreams() {
        scanObserverTask = Task {
            for await results in client.scanResults {
                await MainActor.run {
                    self.latestRawScanResults = results
                    self.discoveredDeviceCount = results.count
                    self.scanResults = self.filterScanResults(results)
                    if self.isScanning && results.isEmpty {
                        self.latestLog = "Scanning..."
                    } else if self.isScanning && self.scanResults.isEmpty {
                        self.latestLog = "Found \(results.count) BLE device(s), none matched Clip name."
                    } else if self.isScanning {
                        self.latestLog = "Found \(self.scanResults.count) Clip device(s)."
                    }
                }
            }
        }
        adapterObserverTask = Task {
            for await state in client.adapterState {
                await MainActor.run {
                    self.adapterState = self.describe(state)
                }
            }
        }
        scanningObserverTask = Task {
            for await scanning in client.isScanning {
                await MainActor.run {
                    self.isScanning = scanning
                    if scanning {
                        self.statusLabel = "scanning"
                    } else if self.statusLabel == "scanning" {
                        self.statusLabel = "scan stopped"
                    }
                }
            }
        }
    }

    private func bindDeviceEvents() {
        guard let recordingSession else { return }
        deviceEventTask?.cancel()
        deviceEventTask = Task {
            for await event in recordingSession.deviceEvents() {
                await MainActor.run {
                    self.log(self.describe(event))
                }
            }
        }
    }

    private func describe(_ event: DeviceEvent) -> String {
        switch event {
        case .recordingState(let state, let sessionId, let durationSeconds, let mode, _):
            return "EVENT state=\(state.rawValue) session=\(sessionId ?? "-") duration=\(durationSeconds ?? -1) mode=\(mode?.rawValue ?? "-")"
        case .bookmark(let sessionId, let markCount, let offsetSeconds, _, _):
            return "EVENT bookmark session=\(sessionId ?? "-") count=\(markCount ?? -1) offset=\(offsetSeconds ?? -1)"
        case .batteryLow(let level, _):
            return "EVENT battery_low level=\(level ?? -1)"
        case .storageLow(let freeMb, _):
            return "EVENT storage_low freeMb=\(freeMb ?? -1)"
        case .error(let code, let message, _):
            return "EVENT error code=\(code ?? -1) message=\(message ?? "-")"
        case .connected(let address, _):
            return "EVENT connected \(address ?? "-")"
        case .disconnected(let reason, _):
            return "EVENT disconnected \(reason ?? "-")"
        case .unknown(let name, _):
            return "EVENT \(name)"
        }
    }

    private func describe(_ status: DeviceStatus) -> String {
        var parts = ["state=\(status.state.isEmpty ? "-" : status.state)"]
        parts.append("recording=\(status.isRecording)")
        if let sessionId = status.sessionId { parts.append("session=\(sessionId)") }
        if let battery = status.batteryPercent { parts.append("battery=\(battery)%") }
        if let firmware = status.firmwareVersion { parts.append("fw=\(firmware)") }
        if let mode = status.recordingMode { parts.append("mode=\(mode.rawValue)") }
        if let seconds = status.recordingSeconds { parts.append("seconds=\(seconds)") }
        return parts.joined(separator: " ")
    }

    private func describe(_ info: DeviceRuntimeInfo) -> String {
        var parts: [String] = []
        if let firmware = info.firmwareVersion { parts.append("fw=\(firmware)") }
        if let state = info.state, !state.isEmpty { parts.append("state=\(state)") }
        if let recording = info.isRecording { parts.append("recording=\(recording)") }
        if let session = info.sessionId { parts.append("session=\(session)") }
        if let battery = info.batteryPercent { parts.append("battery=\(battery)%") }
        if let time = info.formattedDeviceTime { parts.append("time=\(time)") }
        if let pair = info.pairStatus { parts.append("pair=\(pair)") }
        if let address = info.pairAddress { parts.append("peer=\(address)") }
        return parts.isEmpty ? "no runtime fields" : parts.joined(separator: " ")
    }

    private func describe(_ info: DeviceTimeInfo) -> String {
        if let date = info.date {
            return "time=\(shortDateFormatter.string(from: date)) unix=\(info.unixSeconds ?? -1)"
        }
        if let unix = info.unixSeconds {
            return "time=unix(\(unix))"
        }
        return "time=unknown"
    }

    private func describe(_ info: PairingStatus) -> String {
        var parts: [String] = []
        if let paired = info.isPaired {
            parts.append("paired=\(paired)")
        }
        if let state = info.state, !state.isEmpty {
            parts.append("state=\(state)")
        }
        return parts.isEmpty ? "pairing=unknown" : parts.joined(separator: " ")
    }

    private func describeFileSummary(_ files: [DeviceFileMeta]) -> String {
        let totalBytes = files.reduce(0) { $0 + $1.sizeBytes }
        return "\(files.count) file(s), \(totalBytes) bytes"
    }

    private func describe(_ file: DeviceFileMeta) -> String {
        let created = file.createdAt.map { shortDateFormatter.string(from: $0) } ?? "-"
        return "\(file.path) size=\(file.sizeBytes) duration=\(file.durationSeconds) bookmarks=\(file.bookmarkCount) created=\(created)"
    }

    private func inferSessionId(from path: String?) -> String? {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.contains("/") {
            return clean.split(separator: "/").first.map(String.init)
        }
        if let dot = clean.firstIndex(of: ".") {
            return String(clean[..<dot])
        }
        return clean
    }

    private var shortDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:
            return "poweredOn"
        case .poweredOff:
            return "poweredOff"
        case .unauthorized:
            return "unauthorized"
        case .unsupported:
            return "unsupported"
        case .resetting:
            return "resetting"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        SenseCraftVoiceConnection.describe(properties)
    }

    private func waitForBluetoothReady(timeout: TimeInterval) async -> Bool {
        if client.currentAdapterState == .poweredOn {
            adapterState = describe(client.currentAdapterState)
            return true
        }

        log("Waiting for Bluetooth adapter. Current state: \(describe(client.currentAdapterState))")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            adapterState = describe(client.currentAdapterState)
            if client.currentAdapterState == .poweredOn {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        adapterState = describe(client.currentAdapterState)
        return client.currentAdapterState == .poweredOn
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private func copyIntoAppSandbox(_ url: URL) throws -> URL {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let firmwareDir = documentsDirectory().appendingPathComponent("SenseCraftFirmware", isDirectory: true)
        try FileManager.default.createDirectory(at: firmwareDir, withIntermediateDirectories: true)
        let destination = firmwareDir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "0%" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        latestLog = message
        logs.insert("[\(stamp)] \(message)", at: 0)
    }
}
