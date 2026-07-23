import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var vm = VerifyViewModel()
    @State private var showFirmwarePicker = false

    var body: some View {
        TabView {
            navigationShell {
                VStack(alignment: .leading, spacing: 16) {
                    statusPanel
                    actionPanel
                    sdkPanel
                    smokePanel
                    connectionPanel
                    scanPanel
                }
            }
            .tabItem { Label("Control", systemImage: "antenna.radiowaves.left.and.right") }

            navigationShell {
                VStack(alignment: .leading, spacing: 16) {
                    wifiPanel
                    downloadPanel
                }
            }
            .tabItem { Label("Wi-Fi", systemImage: "wifi") }

            navigationShell {
                VStack(alignment: .leading, spacing: 16) {
                    otaPanel
                }
            }
            .tabItem { Label("OTA", systemImage: "arrow.triangle.2.circlepath") }

            navigationShell {
                logPanel
            }
            .tabItem { Label("Logs", systemImage: "text.alignleft") }
        }
        .fileImporter(
            isPresented: $showFirmwarePicker,
            allowedContentTypes: [.zip, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { vm.pickFirmware(url: url) }
            case .failure(let error):
                vm.logs.insert("Firmware pick failed: \(error.localizedDescription)", at: 0)
            }
        }
        .onChange(of: vm.showOnlyProjectDevices) { _ in
            vm.applyProjectDeviceFilter()
        }
    }

    private func navigationShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding()
            }
            .navigationTitle("SenseCraft Verify")
        }
    }

    private var statusPanel: some View {
        SectionCard(title: "Status") {
            LabelRow(label: "Adapter", value: vm.adapterState)
            LabelRow(label: "Connection", value: vm.connectedDeviceLabel)
            LabelRow(label: "State", value: vm.statusLabel)
            LabelRow(label: "Recording", value: vm.activeSessionId.isEmpty ? "idle" : vm.activeSessionId)
            LabelRow(label: "Wi-Fi", value: vm.wifiSessionId.isEmpty ? "idle" : vm.wifiSessionId)
            LabelRow(label: "Runtime", value: vm.runtimeSummary)
            LabelRow(label: "Device name", value: vm.deviceNameSummary)
            LabelRow(label: "Device time", value: vm.deviceTimeSummary)
            LabelRow(label: "Pairing", value: vm.pairingSummary)
            LabelRow(label: "Files", value: vm.filesSummary)
            LabelRow(label: "Last", value: vm.latestLog)
        }
    }

    private var actionPanel: some View {
        SectionCard(title: "Actions") {
            gridButtons([
                ("Local Smoke", "checkmark.seal", vm.localSmoke),
                (vm.isScanning ? "Scanning" : "Scan", "magnifyingglass", vm.startScan),
                ("Stop Scan", "stop.circle", vm.stopScan),
                ("Disconnect", "bolt.slash", vm.disconnect),
            ])
            Button {
                vm.refreshStatus()
            } label: {
                Label("Status", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!vm.isConnected)
        }
    }

    private var sdkPanel: some View {
        SectionCard(title: "SDK APIs") {
            gridButtons([
                ("Runtime", "cpu", vm.readRuntimeInfo),
                ("Sync Time", "clock.arrow.circlepath", vm.syncDeviceTime),
                ("Mark", "bookmark", vm.markBookmark),
                ("List Files", "list.bullet.rectangle", vm.listAllFiles),
            ])
            .disabled(!vm.isConnected)

            gridButtons([
                ("Pause", "pause.fill", vm.pauseRecording),
                ("Resume", "play.fill", vm.resumeRecording),
                ("Mode", "switch.2", vm.applyRecordingMode),
                ("Time", "clock", vm.readDeviceTime),
            ])
            .disabled(!vm.isConnected)

            gridButtons([
                ("Pair", "person.crop.circle", vm.readPairingStatus),
                ("Reset Pair", "arrow.uturn.backward", vm.resetPairing),
                ("Read Name", "tag", vm.readUserDeviceName),
                ("Set Name", "pencil", vm.setUserDeviceName),
            ])
            .disabled(!vm.isConnected)

            Button {
                vm.listBookmarksForEnteredSession()
            } label: {
                Label("List Bookmarks", systemImage: "bookmark.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!vm.isConnected || vm.downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var smokePanel: some View {
        SectionCard(title: "Smoke") {
            Toggle("Only Clip devices", isOn: $vm.showOnlyProjectDevices)
                .toggleStyle(.switch)
            Toggle("Use service UUID scan", isOn: $vm.filterScanByService)
                .toggleStyle(.switch)
            Toggle("Enhanced mode", isOn: $vm.recordingModeIsEnhanced)
                .toggleStyle(.switch)
            Toggle("Join phone Wi-Fi", isOn: $vm.joinPhoneOnWifi)
                .toggleStyle(.switch)
            Toggle("Require join", isOn: $vm.requirePhoneJoin)
                .toggleStyle(.switch)
        }
    }

    private var connectionPanel: some View {
        SectionCard(title: "Device") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Device name (optional)", text: $vm.deviceNameInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Peripheral UUID", text: $vm.manualPeripheralId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button {
                        vm.connectByEnteredId()
                    } label: {
                        Label("Connect", systemImage: "link")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack {
                    TextField("Recording session id", text: $vm.downloadSessionId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Start") { vm.startRecording() }
                        .buttonStyle(.bordered)
                        .disabled(!vm.isConnected)
                    Button("Stop") { vm.stopRecording() }
                        .buttonStyle(.bordered)
                        .disabled(!vm.isConnected)
                }
            }
        }
    }

    private var scanPanel: some View {
        SectionCard(title: "Scan Results") {
            LabelRow(
                label: "Found",
                value: "\(vm.scanResults.count) shown / \(vm.discoveredDeviceCount) scanned"
            )
            if vm.scanResults.isEmpty {
                Text("No devices yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.scanResults) { result in
                    Button {
                        vm.connect(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name)
                                .font(.headline)
                            Text(result.id.uuidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(vm.describeScanResult(result))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private var wifiPanel: some View {
        SectionCard(title: "Wi-Fi Hotspot") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Button {
                        vm.prepareWifi()
                    } label: {
                        Label("Prepare", systemImage: "wifi")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected)

                    Button {
                        vm.pingWifi()
                    } label: {
                        Label("Ping", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected || vm.wifiSessionId.isEmpty)

                    Button {
                        vm.downloadSession()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected)
                }

                ProgressMeter(title: "Wi-Fi progress", value: vm.wifiProgress, label: vm.wifiProgressText)
            }
        }
    }

    private var downloadPanel: some View {
        SectionCard(title: "Download") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Start file (optional)", text: $vm.downloadStartFile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Text("Target folder: Documents/SenseCraftDownloads/<session id>")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Button {
                        vm.bleDownloadMerge()
                    } label: {
                        Label("BLE Merge", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected || vm.downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        vm.bleDownloadFinalize()
                    } label: {
                        Label("BLE Finalize", systemImage: "checkmark.rectangle.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.isConnected || vm.downloadSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var otaPanel: some View {
        SectionCard(title: "OTA") {
            VStack(alignment: .leading, spacing: 12) {
                Label(vm.otaFileLabel, systemImage: "doc")
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        showFirmwarePicker = true
                    } label: {
                        Label("Pick Firmware", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.startOta()
                    } label: {
                        Label("Start OTA", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.isConnected)
                }

                ProgressMeter(title: "OTA progress", value: vm.otaProgress, label: vm.otaProgressText)
            }
        }
    }

    private var logPanel: some View {
        SectionCard(title: "Logs") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(vm.logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func gridButtons(_ actions: [(String, String, () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                Button {
                    item.2()
                } label: {
                    Label(item.0, systemImage: item.1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LabelRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ProgressMeter: View {
    let title: String
    let value: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, value)))
        }
    }
}
