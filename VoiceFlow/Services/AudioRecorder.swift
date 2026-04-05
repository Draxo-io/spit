import AVFoundation
import Combine

// MARK: - AudioRecorder
// Grava áudio usando o dispositivo de entrada padrão do sistema.
// Detecta automaticamente mudanças de dispositivo.

class AudioRecorder: NSObject {

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var startTime: Date?
    private var deviceChangeObserver: NSObjectProtocol?

    var onDeviceChanged: (() -> Void)?
    var onLevelUpdate: ((Float) -> Void)?
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?  // raw buffers for live speech recognizer

    // MARK: - Silence Auto-Stop
    /// Called on main thread when silence exceeds silenceAutoStopSeconds.
    var onSilenceAutoStop: (() -> Void)?
    /// Seconds of continuous silence before firing onSilenceAutoStop. nil = disabled.
    var silenceAutoStopSeconds: Double? = nil
    /// dB level below which audio is considered silence.
    var silenceThresholdDB: Float = -38.0

    private var silenceStartTime: Date? = nil
    private var minimumRecordingSeconds: Double = 1.5  // don't auto-stop before this

    // MARK: - Iniciar Gravação

    func startRecording() throws -> URL {
        stopRecording()

        // Criar ficheiro temporário
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        recordingURL = tempURL

        // Configurar engine
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Configurar ficheiro de output em formato compatível com Whisper (m4a/wav)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        audioFile = try AVAudioFile(forWriting: tempURL, settings: outputFormat.settings)
        let audioFile = self.audioFile!

        // Instalar tap no input — buffer em tempo real
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let monoBuffer = self?.convertToMono(buffer: buffer, outputFormat: outputFormat) else { return }
            try? audioFile.write(from: monoBuffer)
            self?.calculateLevel(buffer: monoBuffer)
            self?.checkSilence(buffer: monoBuffer)

            // Feed raw buffer to live speech recognizer (uses original format, not mono)
            self?.onAudioBuffer?(buffer)
        }

        // Observar mudanças de dispositivo
        observeDeviceChanges()

        try engine.start()
        startTime = Date()

        print("[AudioRecorder] Gravação iniciada: \(tempURL.lastPathComponent)")
        return tempURL
    }

    // MARK: - Parar Gravação

    // MARK: - Silence Detection

    private func checkSilence(buffer: AVAudioPCMBuffer) {
        guard let autoStopSeconds = silenceAutoStopSeconds,
              let start = startTime,
              Date().timeIntervalSince(start) >= minimumRecordingSeconds else {
            return
        }

        // Compute RMS dB for this buffer
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameLength { sum += channelData[i] * channelData[i] }
        let db = 20 * log10(max(sqrt(sum / Float(frameLength)), 0.000001))

        if db < silenceThresholdDB {
            // Below threshold — start or extend silence window
            if silenceStartTime == nil {
                silenceStartTime = Date()
            } else if Date().timeIntervalSince(silenceStartTime!) >= autoStopSeconds {
                silenceStartTime = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceAutoStop?()
                }
            }
        } else {
            // Sound detected — reset silence window
            silenceStartTime = nil
        }
    }

    @discardableResult
    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard let engine = audioEngine, engine.isRunning else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        silenceStartTime = nil

        removeDeviceObserver()

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        startTime = nil

        guard let url = recordingURL else { return nil }
        recordingURL = nil
        audioFile = nil

        print("[AudioRecorder] Gravação terminada — duração: \(String(format: "%.1f", duration))s")
        return (url, duration)
    }

    // MARK: - Conversão Mono

    private func convertToMono(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) *
            outputFormat.sampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return nil
        }
        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }
        return error == nil ? outputBuffer : nil
    }

    // MARK: - Nível de Áudio

    private func calculateLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 0.000001))

        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(db)
        }
    }

    // MARK: - Observar Mudança de Dispositivo

    private func observeDeviceChanges() {
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AudioRecorder] Dispositivo de áudio alterado")
            self?.onDeviceChanged?()
        }
    }

    private func removeDeviceObserver() {
        if let obs = deviceChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            deviceChangeObserver = nil
        }
    }

    deinit {
        stopRecording()
        removeDeviceObserver()
    }
}
