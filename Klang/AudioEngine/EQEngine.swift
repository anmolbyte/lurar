import Foundation
import AVFoundation
import CoreAudio
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "EQEngine")

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var currentPreset: EQPreset?

    // Signal flow:
    //   inputNode (AUHAL bound to BlackHole) → EQ1 → EQ2 → EQ3 → EQ4 → mainMixer (muted)
    //                                                      ↓
    //                                                  installTap → ringBuffer
    //                                                                    ↓
    //                                                              HALOutput (chosen device)
    //
    // We don't use engine.outputNode for actual output because AVAudioEngine on macOS rebinds
    // its CurrentDevice to the system default during init and rejects post-init changes. The
    // engine's outputNode still exists in the graph (mainMixer auto-connects to it) but its
    // signal is muted so nothing audible leaks through it (which would feed BlackHole and loop).
    private var engine = AVAudioEngine()
    private var eqNodes: [AVAudioUnitEQ] = (0..<4).map { _ in AVAudioUnitEQ(numberOfBands: 1) }

    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 sec @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)

    private var activeSampleRate: Double?

    // Devices currently driving the running graph. Held separately from DeviceManager's
    // selection so an auto-restart uses the same devices the engine was started with, even if
    // the user is mid-fiddling with the pickers.
    private var activeInput: AudioDevice?
    private var activeOutput: AudioDevice?

    // Runtime listeners for configuration changes that would otherwise leave the graph stranded
    // (e.g. when a music app changes BlackHole's rate on a track change — AVAudioEngine stops
    // itself in that case and we have to restart).
    private var configChangeObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast

    // MARK: - Lifecycle

    func start(input: AudioDevice, output: AudioDevice) {
        start(input: input, output: output, force: false)
    }

    /// `force` skips the no-op guard. Used by sample-rate / configuration listeners that need a
    /// real rebuild even though the device IDs are unchanged.
    private func start(input: AudioDevice, output: AudioDevice, force: Bool) {
        // Skip no-op restarts. If we're already running on these exact devices (by stable UID;
        // AudioDeviceID can churn when a device blinks out of the device list and back, which
        // happens often with Bluetooth profile switches), a topology refresh shouldn't force us
        // to tear down and rebuild — that rebuild is what actually breaks the AU graph.
        if !force, isRunning, activeInput?.uid == input.uid, activeOutput?.uid == output.uid {
            log.info("[klang-fix] Skipping restart: already running on \(input.name) → \(output.name)")
            return
        }
        log.info("[klang-fix] start(force=\(force)) input=\(input.name)/\(input.uid) output=\(output.name)/\(output.uid) prev=\(self.activeInput?.uid ?? "nil")→\(self.activeOutput?.uid ?? "nil") running=\(self.isRunning)")

        // 1. Tear down prior listeners + HAL output. Note: we deliberately do NOT recreate
        //    `engine` below. Recreating AVAudioEngine causes its fresh inputNode to briefly
        //    grab the system-default input AU; on a Mac with AirPods Pro as the default input,
        //    that grab flips AirPods into HFP/handsfree at 24 kHz mono and breaks reconcile.
        //    Reusing the same engine instance keeps inputNode bound to BlackHole across
        //    restarts.
        teardownChangeObservers()
        if engine.isRunning { engine.stop() }
        engine.reset()
        // Detach previous EQ nodes from the (reused) engine so they don't accumulate.
        for eq in eqNodes { engine.detach(eq) }
        try? halOutput.stop()

        // 2. Reconcile sample rates between input and output devices.
        let sampleRate: Double
        do {
            sampleRate = try CoreAudioSampleRate.reconcile(input: input.id, output: output.id)
            if try CoreAudioSampleRate.nominal(for: input.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: input.id)
            }
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
            }
            activeSampleRate = sampleRate
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Sample-rate reconciliation failed: \(String(describing: error))")
            return
        }

        // 3. Client format that flows through the chain AND that the HAL output expects.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            statusMessage = "Error: could not build client format"
            return
        }
        log.info("Client format: \(clientFormat)")

        // 4. Reuse the existing `engine` instance (see comment in step 1 above).

        do {
            // 5. Bind input device on the engine's input node.
            try AUHAL.bindInput(input.id, to: engine.inputNode, clientFormat: clientFormat)

            // 6. Build the EQ chain. We deliberately do NOT touch engine.mainMixerNode or
            //    engine.outputNode — both are lazily created on first access, and accessing
            //    them instantiates a HAL output AU bound to the system default device. When
            //    BlackHole is the system default (the user's setup), that second AU lands on
            //    the same device as the input AU and the engine wedges. The tap installed at
            //    the end of the chain is what pulls samples through.
            eqNodes = (0..<4).map { _ in AVAudioUnitEQ(numberOfBands: 1) }
            for eq in eqNodes { engine.attach(eq) }
            engine.connect(engine.inputNode, to: eqNodes[0], format: clientFormat)
            for i in 0..<(eqNodes.count - 1) {
                engine.connect(eqNodes[i], to: eqNodes[i + 1], format: clientFormat)
            }

            // 6b. Raise MaximumFramesPerSlice on every AU in the chain. The default of 512 is
            //     too tight; we've seen the input AU push 1115-frame bursts during sample-rate
            //     transitions, which would otherwise trip `kAudioUnitErr_TooManyFramesToProcess`
            //     (-10874) on the next node and stall rendering.
            let maxFrames: UInt32 = 4096
            AUHAL.setMaxFramesPerSlice(maxFrames, on: engine.inputNode.audioUnit)
            for eq in eqNodes {
                AUHAL.setMaxFramesPerSlice(maxFrames, on: eq.audioUnit)
            }

            // 8. Re-apply current preset.
            if let preset = currentPreset { applyPresetToNodes(preset) }

            // 9. Install the tap that ferries processed audio into the ring buffer.
            eqNodes.last?.removeTap(onBus: 0)
            eqNodes.last?.installTap(onBus: 0, bufferSize: 1024, format: clientFormat) { [ringBuffer] buffer, _ in
                Self.feedRingBuffer(buffer, ringBuffer: ringBuffer)
            }

            // 10. Start the AVAudioEngine (drives input + EQ processing).
            engine.prepare()
            try engine.start()

            // 11. Start the HAL Output AU on the user's chosen device.
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeInput = input
            activeOutput = output
            isRunning = true
            statusMessage = "Running · \(input.name) → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine started: \(self.statusMessage)")

            // Suppress AVAudioEngineConfigurationChange notifications that the freshly-started
            // engine emits ~80ms from now as part of its own settle. Real device-side changes
            // that arrive >0.5s after start still get handled.
            restartCooldownUntil = Date().addingTimeInterval(0.5)

            // 12. Install runtime listeners so a track change (or other rate flip) re-reconciles.
            installChangeObservers(input: input, output: output)
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? halOutput.stop()
            if engine.isRunning { engine.stop() }
        }
    }

    func stop() {
        teardownChangeObservers()
        eqNodes.last?.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? halOutput.stop()
        ringBuffer.reset()
        activeInput = nil
        activeOutput = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installChangeObservers(input: AudioDevice, output: AudioDevice) {
        _ = input; _ = output
        // AVAudioEngine stops itself when the underlying I/O unit configuration changes (e.g.
        // BlackHole's HW format flipping on a track change) and posts this notification. We must
        // restart, otherwise audio stays dead.
        //
        // However, AVAudioEngine *also* emits this notification ~80ms after every successful
        // `start()` as a side effect of its own post-start config settle. Without a cooldown
        // that fired an infinite restart loop in earlier iterations. The cooldown set in
        // `recordSuccessfulStart()` swallows those self-induced fires.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date() < self.restartCooldownUntil {
                    log.info("[klang-fix] Ignoring AVAudioEngineConfigurationChange during cooldown")
                    return
                }
                self.scheduleRestart(reason: "AVAudioEngineConfigurationChange")
            }
        }
    }

    private func teardownChangeObservers() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
    }

    private func scheduleRestart(reason: String) {
        guard isRunning, activeInput != nil, activeOutput != nil else { return }
        log.info("Scheduling engine restart: \(reason)")
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning,
                      let input = self.activeInput,
                      let output = self.activeOutput else { return }
                self.start(input: input, output: output, force: true)
            }
        }
        pendingRestart = work
        // Track changes can fire several property notifications in rapid succession; debounce so
        // we only restart once per burst.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reportStartFailure(_ message: String) {
        isRunning = false
        statusMessage = message
        log.error("Start blocked: \(message)")
    }

    // MARK: - Preset / band updates

    func apply(preset: EQPreset) {
        currentPreset = preset
        applyPresetToNodes(preset)
    }

    private func applyPresetToNodes(_ preset: EQPreset) {
        eqNodes[0].globalGain = preset.preamp
        for i in 1..<eqNodes.count {
            eqNodes[i].globalGain = 0
        }
        for (i, band) in preset.bands.prefix(eqNodes.count).enumerated() {
            applyBand(band, to: eqNodes[i].bands[0])
        }
    }

    func updateBand(index: Int, band: EQBand) {
        guard eqNodes.indices.contains(index) else { return }
        applyBand(band, to: eqNodes[index].bands[0])
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
    }

    func setPreamp(_ dB: Float) {
        eqNodes[0].globalGain = dB
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
    }

    private func applyBand(_ band: EQBand, to auBand: AVAudioUnitEQFilterParameters) {
        auBand.filterType = band.type.auFilterType
        auBand.frequency = band.frequency
        auBand.gain = band.gain
        auBand.bandwidth = band.q.qToBandwidthOctaves
        auBand.bypass = false
    }

    // MARK: - Tap → ring buffer

    private static func feedRingBuffer(_ buffer: AVAudioPCMBuffer, ringBuffer: StereoFloatRingBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        if channels >= 2 {
            ringBuffer.write(left: data[0], right: data[1], frames: frames)
        } else if channels == 1 {
            ringBuffer.write(left: data[0], right: data[0], frames: frames)
        }
    }
}
