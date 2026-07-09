import Foundation
import AVFoundation
import MLXAudioTTS

// MARK: - Voice catalogue

struct MLXVoice: Identifiable, Hashable {
    let id: String          // BCP-47 language tag used in settings
    let langName: String
    let flag: String

    // Languages supported by Qwen3-TTS-12Hz-1.7B.
    // The model's codec_language_id map uses full English names (not BCP-47).
    // MLXTTSService.modelLanguageName(for:) maps id → model name before calling generateStream.
    static let all: [MLXVoice] = [
        .init(id: "zh",    langName: "中文",              flag: "🇨🇳"),
        .init(id: "en",    langName: "English",          flag: "🇺🇸"),
        .init(id: "ja",    langName: "日本語",             flag: "🇯🇵"),
        .init(id: "ko",    langName: "한국어",              flag: "🇰🇷"),
        .init(id: "fr",    langName: "Français",         flag: "🇫🇷"),
        .init(id: "de",    langName: "Deutsch",          flag: "🇩🇪"),
        .init(id: "es",    langName: "Español",          flag: "🇪🇸"),
        .init(id: "it",    langName: "Italiano",         flag: "🇮🇹"),
        .init(id: "pt",    langName: "Português (PT)",   flag: "🇵🇹"),
        .init(id: "pt-BR", langName: "Português (BR)",   flag: "🇧🇷"),
        .init(id: "ru",    langName: "Русский",          flag: "🇷🇺"),
        .init(id: "nl",    langName: "Nederlands",       flag: "🇳🇱"),
        .init(id: "pl",    langName: "Polski",           flag: "🇵🇱"),
        .init(id: "tr",    langName: "Türkçe",           flag: "🇹🇷"),
        .init(id: "ar",    langName: "العربية",           flag: "🇸🇦"),
        .init(id: "hi",    langName: "हिन्दी",             flag: "🇮🇳"),
        .init(id: "uk",    langName: "Українська",       flag: "🇺🇦"),
    ]

    // Set of all supported language IDs (for fast lookup)
    static let supportedIDs: Set<String> = Set(all.map(\.id))
}

// MARK: - MLX TTS Service

// Wraps mlx-audio-swift / Qwen3-TTS (16+ languages, on-device, Apple Silicon).
// Model is downloaded once (~250 MB) from HuggingFace and cached locally.
//
// Streaming approach: uses generateStream() to yield audio chunks every ~25 tokens
// (~2s of audio). Each chunk is scheduled via AVAudioPlayerNode as it arrives.
// First audio plays ~6-8s after trigger instead of waiting ~20s for full generation.
@MainActor
final class MLXTTSService: ObservableObject {

    static let shared = MLXTTSService()

    // Qwen3-TTS 1.7B (8-bit) — better quality than 0.6B, still multilingual (PT included).
    // ~1.7 GB download on first launch; first audio chunk arrives in ~12-15s.
    static let modelRepo = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"

    enum ModelState: Equatable {
        case idle           // never loaded, or unloaded after standby
        case loading        // download + load in progress
        case ready          // model loaded, can speak
        case standingBy     // being unloaded due to inactivity
        case error(String)  // load failed
    }

    @Published private(set) var state: ModelState = .idle
    @Published private(set) var isSpeaking = false
    /// true apenas quando o áudio está realmente a ser reproduzido (não durante a geração).
    @Published private(set) var isPlayingAudio = false

    /// true após o modelo ter atingido .ready alguma vez (distingue 1.ª carga de reload pós-standby).
    private(set) var hasEverBeenReady = false
    /// true após a primeira geração completar (JIT compilation done; próximas gerações são mais rápidas).
    private(set) var hasCompletedFirstGeneration = false

    private var model: (any SpeechGenerationModel)?
    private var speakTask: Task<Void, Never>?
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var engineSetUp = false

    // Tracks streaming completion: isSpeaking goes false only when generation
    // is done AND all queued buffers have finished playing.
    private var pendingBuffers: Int = 0
    private var generationDone: Bool = false

    // Inactivity timer — fires enterStandby() after configured idle period.
    private var inactivityTimer: DispatchSourceTimer?

    private init() {}

    // MARK: - Public API

    var isReady: Bool { state == .ready }

    func loadModel() async {
        guard state == .idle || isErrorState else { return }
        state = .loading
        vfLog("MLXTTSService — loading \(Self.modelRepo)…")
        do {
            // Downloads from HF if not cached; subsequent launches are instant.
            model = try await TTS.loadModel(modelRepo: Self.modelRepo)
            state = .ready
            hasEverBeenReady = true
            vfLog("MLXTTSService — model ready ✅")
        } catch {
            state = .error(error.localizedDescription)
            vfLog("MLXTTSService — load error: \(error)")
        }
    }

    func speak(text: String, language: String) {
        guard let model, state == .ready else {
            vfLog("MLXTTSService — model not ready, skipping")
            return
        }
        cancelInactivityTimer()
        // Set isSpeaking = true SYNCHRONOUSLY so Combine subscribers see it before the task runs.
        speakTask?.cancel()
        speakTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        isSpeaking = true
        pendingBuffers = 0
        generationDone = false
        let capturedModel = model
        let modelLang = Self.modelLanguageName(for: language)

        // ICL (voice cloning) for pt-BR: load bundled reference audio clip recorded with
        // macOS Luciana voice so Qwen3-TTS mimics the Brazilian Portuguese accent.
        // refAudio is 1D float32 MLXArray @24kHz; refText is the clip's transcript.
        // Detached task: generateVoiceDesign() is a blocking computation — must run
        // off-MainActor. generateStream() yields audio chunks (~2s each) as they're generated,
        // so playback starts ~12-15s in instead of waiting for full generation.
        speakTask = Task.detached(priority: .userInitiated) { [weak self] in
            vfLog("MLXTTSService — generating audio stream (bcp47:\(language) → model:\(modelLang))…")
            do {
                var chunkCount = 0
                let stream = capturedModel.generateStream(
                    text: text,
                    voice: nil,
                    refAudio: nil,
                    refText: nil,
                    language: modelLang,
                    generationParameters: capturedModel.defaultGenerationParameters
                )
                for try await event in stream {
                    guard !Task.isCancelled else {
                        vfLog("MLXTTSService — cancelled after \(chunkCount) chunks")
                        await MainActor.run { self?.isSpeaking = false }
                        return
                    }
                    guard case .audio(let mlxArray) = event else { continue }
                    let samples = mlxArray.asArray(Float.self)
                    guard !samples.isEmpty else { continue }
                    chunkCount += 1
                    vfLog("MLXTTSService — chunk \(chunkCount): \(samples.count) samples")
                    await MainActor.run { [weak self] in
                        self?.scheduleChunk(samples, sampleRate: capturedModel.sampleRate)
                    }
                }
                vfLog("MLXTTSService — generation complete (\(chunkCount) chunks)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.generationDone = true
                    if chunkCount == 0 {
                        vfLog("MLXTTSService — no audio generated")
                        self.isSpeaking = false
                    } else {
                        self.checkPlaybackComplete()
                    }
                }
            } catch {
                vfLog("MLXTTSService — speak error: \(error)")
                await MainActor.run { self?.isSpeaking = false }
            }
        }
    }

    func pause() {
        guard isSpeaking else { return }
        playerNode.pause()
        vfLog("MLXTTSService — paused")
    }

    func resume() {
        guard isSpeaking else { return }
        playerNode.play()
        vfLog("MLXTTSService — resumed")
    }

    func cancel() {
        let wasActive = isSpeaking
        speakTask?.cancel()
        speakTask = nil
        cancelInactivityTimer()
        if playerNode.isPlaying { playerNode.stop() }
        pendingBuffers = 0
        generationDone = false
        isPlayingAudio = false
        isSpeaking = false
        if wasActive {
            resetInactivityTimer()
        }
    }

    /// Descarrega o modelo após inatividade — mostra estado .standingBy brevemente, depois .idle.
    func enterStandby() {
        guard state == .ready, !isSpeaking else { return }
        cancelInactivityTimer()
        state = .standingBy
        vfLog("MLXTTSService — entering standby, unloading model in 2.5s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.state == .standingBy else { return }
            self.model = nil
            self.hasCompletedFirstGeneration = false
            self.state = .idle
            vfLog("MLXTTSService — model unloaded (standby)")
        }
    }

    // MARK: - Language mapping

    // The model's codec_language_id map uses full English names (lowercase), not BCP-47 codes.
    // Passing "pt" would silently skip the codec language prefill; "portuguese" enables it.
    // Languages not in this map fall back to auto codec behavior (still generates correctly).

    private static let bcp47ToModelLanguage: [String: String] = [
        "zh": "chinese",
        "en": "english",
        "ja": "japanese",
        "ko": "korean",
        "fr": "french",
        "de": "german",
        "es": "spanish",
        "it": "italian",
        "pt": "portuguese",
        "pt-br": "portuguese",
        "ru": "russian",
    ]

    private static func modelLanguageName(for bcp47: String) -> String {
        bcp47ToModelLanguage[bcp47.lowercased()] ?? bcp47
    }

    // MARK: - Private

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    // loadModel() só pode ser chamado de .idle ou .error — não de .standingBy.
    // isReady exposto para TTSService verificar antes de falar.
    // Nota: .standingBy não é "ready" — o modelo está a ser descarregado.

    /// Schedules one audio chunk. Starts playerNode on first chunk.
    /// Completion callback decrements pendingBuffers and checks if fully done.
    @MainActor
    private func scheduleChunk(_ samples: [Float], sampleRate: Int) {
        ensureAudioEngine(sampleRate: Double(sampleRate))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
        let channelData = buffer.floatChannelData?[0] else {
            vfLog("MLXTTSService — failed to create PCMBuffer for chunk")
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { channelData[i] = samples[i] }

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBuffers -= 1
                self.checkPlaybackComplete()
            }
        }
        if !isPlayingAudio {
            playerNode.play()
            isPlayingAudio = true
            vfLog("MLXTTSService — playback started @ \(sampleRate)Hz")
        }
    }

    /// Sets isSpeaking = false only after all chunks are scheduled AND played back.
    @MainActor
    private func checkPlaybackComplete() {
        guard generationDone, pendingBuffers <= 0 else { return }
        vfLog("MLXTTSService — all chunks played, done")
        hasCompletedFirstGeneration = true
        isPlayingAudio = false
        isSpeaking = false
        resetInactivityTimer()
    }

    // MARK: - Inactivity timer

    private func resetInactivityTimer() {
        cancelInactivityTimer()
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
              settings.ttsInactivityMinutes > 0 else { return }
        let seconds = Double(settings.ttsInactivityMinutes * 60)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.enterStandby() }
        timer.resume()
        inactivityTimer = timer
        vfLog("MLXTTSService — inactivity timer set (\(settings.ttsInactivityMinutes) min)")
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.cancel()
        inactivityTimer = nil
    }

    private func ensureAudioEngine(sampleRate: Double) {
        if !engineSetUp {
            engineSetUp = true
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }
        // Restart engine if it stopped (audio route change, sleep, etc.)
        if !audioEngine.isRunning {
            vfLog("MLXTTSService — restarting audio engine")
            try? audioEngine.start()
        }
    }
}
