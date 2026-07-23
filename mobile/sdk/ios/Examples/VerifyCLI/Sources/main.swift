import CoreBluetooth
import Foundation
import SenseCraftVoiceIOS

@main
struct SenseCraftVoiceVerifyCLI {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case nil, "help", "--help", "-h":
            printUsage()
        case "smoke":
            runSmoke()
        case "scan":
            await runScan(timeout: timeout(from: args, fallback: 12))
        case "status":
            guard args.count >= 2, let id = UUID(uuidString: args[1]) else {
                print("Missing or invalid peripheral UUID.")
                printUsage()
                return
            }
            await runStatus(peripheralId: id)
        default:
            print("Unknown command: \(args[0])")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        SenseCraftVoiceVerifyCLI

        Commands:
          smoke                  Run no-hardware SDK checks.
          scan [seconds]         Scan for SenseCraft Voice BLE devices on macOS.
          status <uuid>          Connect by peripheral UUID and run AT+GSTAT.

        Typical:
          swift run SenseCraftVoiceVerifyCLI smoke
          swift run SenseCraftVoiceVerifyCLI scan 12
        """)
    }

    static func runSmoke() {
        let framer = JsonObjectFramer()
        let chunks = framer.feed("{\"ok\":") + framer.feed("true}")
        precondition(chunks.count == 1, "JsonObjectFramer failed")

        let progress = TransferProgress.wifiAligned(
            framedMode: true,
            currentFileDeclaredSize: 100,
            bytesThisFile: 40,
            receivedSession: 240,
            expectedSession: 1000,
            filesCompleted: 2,
            deviceTotalFiles: 5,
            deviceSessionBytes: 1000
        )
        precondition(abs((progress ?? -1) - 0.24) < 0.0001, "TransferProgress failed")

        let state = BleTransferFrameState()
        let name = Array("0001.opus".utf8)
        var startFrame = Data([kClipFrameFileStart, UInt8(name.count)])
        startFrame.append(contentsOf: name)
        startFrame.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
        if case .fileStart(let filename, let fileSize) = BleTransferFrameHandler.handle(bytes: startFrame, state: state) {
            precondition(filename == "0001.opus" && fileSize == 3, "BleTransferFrameHandler failed")
        } else {
            preconditionFailure("BleTransferFrameHandler did not parse FILE_START")
        }

        print("PASS: SDK local smoke checks passed.")
    }

    @MainActor
    static func runScan(timeout: TimeInterval) async {
        let client = SenseCraftVoiceClient()
        do {
            print("Scanning for \(Int(timeout))s...")
            try await client.startScan(timeout: timeout)
            let deadline = Date().addingTimeInterval(timeout)
            var latest: [ScanResult] = []
            for await results in client.scanResults {
                latest = results
                if !results.isEmpty {
                    for item in results.prefix(8) {
                        print("\(item.id.uuidString)  \(item.name)  rssi=\(item.rssi)")
                    }
                }
                if Date() >= deadline { break }
            }
            client.stopScan()
            if latest.isEmpty {
                print("No devices found. Check Bluetooth permission and that the device is advertising.")
            }
        } catch {
            client.stopScan()
            print("Scan failed: \(error)")
        }
    }

    @MainActor
    static func runStatus(peripheralId: UUID) async {
        let client = SenseCraftVoiceClient()
        do {
            guard let connection = try await client.connect(by: peripheralId) else {
                print("Peripheral not found by UUID: \(peripheralId.uuidString)")
                return
            }
            defer { Task { await client.disconnect(connection) } }
            let at = AtTransport(connection: connection)
            let session = RecordingSession(connection: connection, at: at)
            let status = try await session.getStatus()
            print("PASS: AT+GSTAT -> \(status)")
        } catch {
            print("Status check failed: \(error)")
        }
    }

    static func timeout(from args: [String], fallback: TimeInterval) -> TimeInterval {
        guard args.count >= 2, let value = Double(args[1]), value > 0 else {
            return fallback
        }
        return value
    }
}
