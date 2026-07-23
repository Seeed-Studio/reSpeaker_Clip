import Foundation
import CoreBluetooth

#if canImport(iOSMcuManagerLibrary)
import iOSMcuManagerLibrary

public final class NordicMcuMgrOtaTransport: NSObject, OtaUpgradeTransport, FirmwareUpgradeDelegate {
    private let peripheral: CBPeripheral
    private let configuration: FirmwareUpgradeConfiguration
    private var manager: FirmwareUpgradeManager?
    private var controller: FirmwareUpgradeController?
    private var progressHandler: ((OtaProgress) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var totalBytes = 0

    public init(
        peripheral: CBPeripheral,
        configuration: FirmwareUpgradeConfiguration = FirmwareUpgradeConfiguration(
            estimatedSwapTime: 0,
            eraseAppSettings: true,
            upgradeMode: .confirmOnly
        )
    ) {
        self.peripheral = peripheral
        self.configuration = configuration
    }

    public func upgrade(
        deviceId: String,
        images: [OtaImage],
        progress: @escaping (OtaProgress) -> Void
    ) async throws {
        totalBytes = images.reduce(0) { $0 + $1.data.count }
        progressHandler = progress
        let nativeImages = images.map { image -> ImageManager.Image in
            let hash = (try? McuMgrImage(data: image.data).hash) ?? Data()
            return ImageManager.Image(
                name: image.fileName,
                image: image.imageIndex,
                slot: 1,
                content: .bin,
                hash: hash,
                data: image.data
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let transport = McuMgrBleTransport(peripheral)
            let manager = FirmwareUpgradeManager(transport: transport, delegate: self)
            self.manager = manager
            manager.start(images: nativeImages, using: configuration)
        }
    }

    public func cancel() async {
        manager?.cancel()
        controller?.cancel()
        emit(.cancelled, progress: 0, bytesSent: 0, totalBytes: totalBytes, message: "Cancelled")
        finish()
    }

    public func upgradeDidStart(controller: FirmwareUpgradeController) {
        self.controller = controller
        emit(.preparing, progress: 0, bytesSent: 0, totalBytes: totalBytes, message: "Reading bootloader info...")
    }

    public func upgradeStateDidChange(from previousState: FirmwareUpgradeState, to newState: FirmwareUpgradeState) {
        emit(
            mapState(newState),
            progress: newState == .upload ? 0 : 1,
            bytesSent: newState == .upload ? 0 : totalBytes,
            totalBytes: totalBytes,
            message: stateText(newState)
        )
    }

    public func upgradeDidComplete() {
        emit(.success, progress: 1, bytesSent: totalBytes, totalBytes: totalBytes, message: "Upgrade complete")
        finish()
    }

    public func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        fail(error)
    }

    public func upgradeDidCancel(state: FirmwareUpgradeState) {
        emit(.cancelled, progress: 0, bytesSent: 0, totalBytes: totalBytes, message: "Cancelled")
        fail(SenseCraftVoiceError.internalError("OTA cancelled"))
    }

    public func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        let total = imageSize > 0 ? imageSize : totalBytes
        let ratio = total > 0 ? Double(bytesSent) / Double(total) : 0
        emit(
            .uploading,
            progress: max(0, min(1, ratio)),
            bytesSent: bytesSent,
            totalBytes: total,
            message: "Uploading firmware..."
        )
    }

    private func emit(_ phase: OtaPhase, progress: Double, bytesSent: Int, totalBytes: Int, message: String) {
        progressHandler?(OtaProgress(
            phase: phase,
            progress: progress,
            bytesSent: bytesSent,
            totalBytes: totalBytes,
            message: message
        ))
    }

    private func finish() {
        let continuation = self.continuation
        self.continuation = nil
        self.manager = nil
        self.controller = nil
        continuation?.resume()
    }

    private func fail(_ error: Error) {
        let continuation = self.continuation
        self.continuation = nil
        self.manager = nil
        self.controller = nil
        continuation?.resume(throwing: error)
    }

    private func mapState(_ state: FirmwareUpgradeState) -> OtaPhase {
        switch state {
        case .upload:
            return .uploading
        case .validate, .test, .confirm:
            return .validating
        case .reset, .resetIntoFirmwareLoader:
            return .resetting
        case .success:
            return .success
        case .none, .requestMcuMgrParameters, .bootloaderInfo, .eraseAppSettings:
            return .preparing
        }
    }

    private func stateText(_ state: FirmwareUpgradeState) -> String {
        switch state {
        case .requestMcuMgrParameters:
            return "Requesting parameters..."
        case .bootloaderInfo:
            return "Reading bootloader info..."
        case .eraseAppSettings:
            return "Erasing settings..."
        case .upload:
            return "Uploading firmware..."
        case .validate:
            return "Validating..."
        case .test:
            return "Testing..."
        case .confirm:
            return "Confirming..."
        case .reset, .resetIntoFirmwareLoader:
            return "Resetting device..."
        case .success:
            return "Upgrade complete"
        case .none:
            return "Preparing..."
        }
    }
}
#else
public final class NordicMcuMgrOtaTransport: OtaUpgradeTransport {
    public init(peripheral: CBPeripheral) {}

    public func upgrade(
        deviceId: String,
        images: [OtaImage],
        progress: @escaping (OtaProgress) -> Void
    ) async throws {
        throw SenseCraftVoiceError.unsupported("Add Nordic iOSMcuManagerLibrary to enable NordicMcuMgrOtaTransport")
    }

    public func cancel() async {}
}
#endif
