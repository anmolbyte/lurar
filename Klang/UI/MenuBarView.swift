import SwiftUI
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetStore: PresetStore

    @Environment(\.openWindow) private var openWindow

    @State private var selectedPresetID: UUID?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            engineRow
            presetPicker
            outputPicker
            statusRow

            Divider()

            HStack {
                Button("Open Editor…") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("e", modifiers: [.command])

                Spacer()

                Toggle("Start at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin, initial: false) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            HStack {
                Spacer()
                Button("Quit Klang") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            wireUp()
            applySelectedPreset()
        }
        .onChange(of: selectedPresetID) { _, _ in applySelectedPreset() }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (e.g. editor deleted the current
            // preset and moved to a neighbor). Keep the dropdown in sync.
            if let id = new?.id, id != selectedPresetID {
                selectedPresetID = id
            }
        }
        .onChange(of: deviceManager.selectedOutput) { _, _ in restartIfRunning() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Klang").font(.headline)
                Text("Parametric EQ for headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineRow: some View {
        Toggle(isOn: Binding(
            get: { engine.isRunning },
            set: { newValue in
                if newValue { startEngine() } else { engine.stop() }
            }
        )) {
            Text("Engine")
        }
        .toggleStyle(.switch)
    }

    private var presetPicker: some View {
        HStack {
            Text("Preset")
            Spacer()
            Picker("", selection: $selectedPresetID) {
                ForEach(presetStore.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private var outputPicker: some View {
        HStack {
            Text("Output")
            Spacer()
            Picker("", selection: Binding(
                get: { deviceManager.selectedOutput?.uid ?? "" },
                set: { uid in
                    deviceManager.selectedOutput = deviceManager.outputDevices.first { $0.uid == uid }
                }
            )) {
                ForEach(deviceManager.outputDevices) { dev in
                    Text(dev.name).tag(dev.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engine.statusMessage)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
        }
        .font(.callout)
    }

    // MARK: - Actions

    private func wireUp() {
        if selectedPresetID == nil {
            selectedPresetID = presetStore.presets.first?.id
        }
        deviceManager.onTopologyChange = {
            // If currently running, try to restart with the current selection.
            // If selection went nil (device removed and no fallback), stop.
            restartIfRunning()
        }
    }

    private func applySelectedPreset() {
        guard let id = selectedPresetID,
              let preset = presetStore.presets.first(where: { $0.id == id }) else { return }
        if engine.currentPreset?.id == preset.id { return }
        engine.apply(preset: preset)
    }

    private func startEngine() {
        guard let output = deviceManager.selectedOutput else {
            engine.reportStartFailure("Pick an output device first")
            return
        }
        engine.start(output: output)
    }

    private func restartIfRunning() {
        guard engine.isRunning else { return }
        guard let output = deviceManager.selectedOutput else {
            engine.stop()
            return
        }
        engine.start(output: output)
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch-at-login toggle failed: \(String(describing: error))")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
