import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "EQEngine")

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var currentPreset: EQPreset?

    // Signal flow:
    //   ProcessTap (system audio, excl. own process) → aggregate device
    //     → input AU → EQProcessor (10-band vDSP biquad + preamp) → ring buffer
    //                                                                ↓
    //                                                             HALOutput (DAC)
    //
    // Process Taps (macOS 14.2+) capture system output at the HAL layer without going
    // through an input device, so the orange microphone privacy indicator stays off.
    private let tapInput = ProcessTapInput()
    private let eqProcessor = EQProcessor()
    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 s @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)

    private var activeSampleRate: Double?
    private var activeOutput: AudioDevice?

    // Per-device sample-rate listeners. When the system output rate changes on a track
    // change, the aggregate device wrapping the tap follows; we re-reconcile and restart.
    private var inputRateListener: AudioDevicePropertyListener?
    private var outputRateListener: AudioDevicePropertyListener?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast

    // MARK: - Lifecycle

    func start(output: AudioDevice) {
        log.info("start output=\(output.name)/\(output.uid) prev=\(self.activeOutput?.uid ?? "nil") running=\(self.isRunning)")

        // Fast path: engine is already running and only the output device is changing.
        // The tap + aggregate + input AU don't depend on the output, so leave them up
        // and only re-bind HALOutput. Rebuilding the tap takes ~hundreds of ms and
        // would hang the picker.
        if isRunning, let sampleRate = activeSampleRate, tapInput.deviceID != 0 {
            if rebindOutput(output: output, sampleRate: sampleRate) {
                return
            }
            log.info("Fast-path output rebind failed; falling back to full restart")
        }

        fullStart(output: output)
    }

    private func rebindOutput(output: AudioDevice, sampleRate: Double) -> Bool {
        outputRateListener = nil
        do {
            try halOutput.stop()
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
            }
            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            ) else {
                return false
            }
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeOutput = output
            statusMessage = "Running · System → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine output rebound: \(self.statusMessage)")
            installOutputRateListener(output: output)
            restartCooldownUntil = Date().addingTimeInterval(0.5)
            return true
        } catch {
            log.error("rebindOutput failed: \(String(describing: error))")
            try? halOutput.stop()
            return false
        }
    }

    private func fullStart(output: AudioDevice) {
        tearDownListeners()
        try? tapInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()

        // 0. Process Tap API requires the private TCC service kTCCServiceAudioCapture.
        //    Without it the tap silently delivers zero buffers. Prompt the user if
        //    not yet authorized.
        if !AudioCapturePermission.ensureAuthorized() {
            isRunning = false
            statusMessage = "Audio capture permission denied. Grant in System Settings → Privacy & Security."
            log.error("Engine start aborted: TCC audio capture not authorized")
            return
        }

        // 1. Create the process tap + aggregate device. The aggregate's nominal rate
        //    follows the tap (system audio rate). Conform the output device to that
        //    rate if it differs and the output supports it.
        let inputDeviceID: AudioDeviceID
        let sampleRate: Double
        do {
            let prepared = try tapInput.prepare()
            inputDeviceID = prepared.deviceID
            sampleRate = prepared.sampleRate
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                if CoreAudioSampleRate.supports(sampleRate, for: output.id) {
                    try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
                } else {
                    log.info("Output \(output.name) does not support tap rate \(sampleRate); leaving as-is and relying on HAL conversion")
                }
            }
            activeSampleRate = sampleRate
        } catch {
            try? tapInput.stop()
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Tap setup failed: \(String(describing: error))")
            return
        }

        // 2. Client format for the output side. Tap input feeds the EQ at the tap's
        //    native format; HALOutput pulls Float32 stereo from the ring buffer.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            try? tapInput.stop()
            statusMessage = "Error: could not build client format"
            return
        }
        log.info("Client format: \(clientFormat)")

        // 3. Push current preset into the EQ processor so coefficients are ready before
        //    the first input callback fires.
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        }

        // 4. Start the tap IOProc. Its callback runs on the audio thread: EQ in-place
        //    on scratch buffers, then write to the ring buffer.
        do {
            try tapInput.start { [eqProcessor, ringBuffer] left, right, frames in
                eqProcessor.process(left: left, right: right, frames: frames)
                ringBuffer.write(left: left, right: right, frames: frames)
            }

            // 5. Start the output AU on the user's chosen device.
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeOutput = output
            isRunning = true
            statusMessage = "Running · System → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine started: \(self.statusMessage)")

            restartCooldownUntil = Date().addingTimeInterval(0.5)

            installListeners(inputDeviceID: inputDeviceID, output: output)
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? tapInput.stop()
            try? halOutput.stop()
        }
    }

    func stop() {
        tearDownListeners()
        try? tapInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()
        activeOutput = nil
        activeSampleRate = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installListeners(inputDeviceID: AudioDeviceID, output: AudioDevice) {
        inputRateListener = AudioDevicePropertyListener(
            deviceID: inputDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRestart(reason: "tap rate change") }
        }
        installOutputRateListener(output: output)
    }

    private func installOutputRateListener(output: AudioDevice) {
        outputRateListener = AudioDevicePropertyListener(
            deviceID: output.id,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRestart(reason: "output rate change") }
        }
    }

    private func tearDownListeners() {
        pendingRestart?.cancel()
        pendingRestart = nil
        inputRateListener = nil
        outputRateListener = nil
    }

    private func scheduleRestart(reason: String) {
        guard isRunning, activeOutput != nil else { return }
        if Date() < restartCooldownUntil {
            log.info("Ignoring \(reason) during cooldown")
            return
        }
        log.info("Scheduling engine restart: \(reason)")
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, let output = self.activeOutput else { return }
                // SR changed: the input AU's client format is stale, so a fast-path
                // output-only rebind is not enough. Force a full teardown + rebuild.
                self.fullStart(output: output)
            }
        }
        pendingRestart = work
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
        if let sampleRate = activeSampleRate {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        } else {
            eqProcessor.configure(preset: preset, sampleRate: 48_000)
        }
    }

    func updateBand(index: Int, band: EQBand) {
        eqProcessor.updateBand(index: index, band: band)
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
    }

    func setPreamp(_ dB: Float) {
        eqProcessor.setPreamp(dB: dB)
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
    }
}
