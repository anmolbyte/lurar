import SwiftUI
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    @Environment(\.openWindow) private var openWindow

    @State private var selectedPresetID: UUID?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    /// Catalog-enabled built-ins first, then the user's own presets. The catalog
    /// section is empty until the index loads and entries hydrate.
    private var visiblePresets: [EQPreset] {
        presetCatalog.enabledPresets + presetStore.presets
    }

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

    /// Label column width shared by Preset/Output/Status rows so the right-hand
    /// controls line up cleanly. Picked to fit "Preset" / "Output" / "Status" at
    /// the body font without truncation.
    private let labelColumnWidth: CGFloat = 56

    /// Width of the dropdown chrome. `Picker` (NSPopUpButton) ignores `.frame`,
    /// so we use `Menu` instead and constrain its label — Menu *does* honor it.
    private let pickerWidth: CGFloat = 232

    private var presetPicker: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .frame(width: labelColumnWidth, alignment: .leading)
            FixedWidthPopUp(
                width: pickerWidth,
                selection: Binding(
                    get: { selectedPresetID?.uuidString ?? "" },
                    set: { uuidString in
                        selectedPresetID = UUID(uuidString: uuidString)
                    }
                ),
                items: visiblePresets.map { preset in
                    .init(id: preset.id.uuidString, title: presetMenuLabel(for: preset))
                }
            )
            .disabled(visiblePresets.isEmpty)
        }
    }

    private func presetMenuLabel(for preset: EQPreset) -> String {
        let suffix = presetSourceSuffix(for: preset)
        guard !suffix.isEmpty else { return preset.name }
        // Don't double-up if the preset name already ends with this source (some
        // legacy bundled names already had the source baked in).
        if preset.name.lowercased().hasSuffix(suffix.lowercased()) {
            return preset.name
        }
        return "\(preset.name) · \(suffix)"
    }

    /// Pick a short disambiguating tag from `source`. Klang's own user presets get
    /// no suffix; catalog entries surface their measurer/rig.
    private func presetSourceSuffix(for preset: EQPreset) -> String {
        let trimmed = preset.source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("Klang") == .orderedSame {
            return ""
        }
        return trimmed
    }

    private var outputPicker: some View {
        HStack(spacing: 8) {
            Text("Output")
                .frame(width: labelColumnWidth, alignment: .leading)
            FixedWidthPopUp(
                width: pickerWidth,
                selection: Binding(
                    get: { deviceManager.selectedOutput?.uid ?? "" },
                    set: { uid in
                        deviceManager.selectedOutput = deviceManager.outputDevices.first { $0.uid == uid }
                    }
                ),
                items: deviceManager.outputDevices.map { .init(id: $0.uid, title: $0.name) }
            )
            .disabled(deviceManager.outputDevices.isEmpty)
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top) {
            Text("Status")
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(engine.statusMessage)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .font(.callout)
    }

    // MARK: - Actions

    private func wireUp() {
        if selectedPresetID == nil {
            selectedPresetID = visiblePresets.first?.id
        }
        deviceManager.onTopologyChange = {
            // If currently running, try to restart with the current selection.
            // If selection went nil (device removed and no fallback), stop.
            restartIfRunning()
        }
    }

    private func applySelectedPreset() {
        guard let id = selectedPresetID,
              let preset = visiblePresets.first(where: { $0.id == id }) else { return }
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

// MARK: - Fixed-width popup

/// Wraps `NSPopUpButton` so we can hand it an explicit width that it actually
/// respects. SwiftUI's `Picker` and `Menu` both bridge to AppKit chrome that
/// content-hugs and ignores `.frame(width:)`, which is why we drop to AppKit.
private struct FixedWidthPopUp: NSViewRepresentable {
    struct Item: Hashable {
        let id: String
        let title: String
    }

    let width: CGFloat
    @Binding var selection: String
    let items: [Item]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24), pullsDown: false)
        button.controlSize = .regular
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        // Rebuild items only if the set changed — preserves selection animation.
        let titles = items.map(\.title)
        let existing = button.itemArray.map(\.title)
        if titles != existing {
            button.removeAllItems()
            for item in items {
                button.addItem(withTitle: item.title)
                button.lastItem?.representedObject = item.id
            }
        }
        if let index = items.firstIndex(where: { $0.id == selection }) {
            if button.indexOfSelectedItem != index {
                button.selectItem(at: index)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: FixedWidthPopUp
        init(_ parent: FixedWidthPopUp) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            parent.selection = id
        }
    }
}
