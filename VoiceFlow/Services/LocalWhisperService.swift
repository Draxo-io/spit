import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - LocalWhisperService
// Transcrição on-device via WhisperKit (CoreML + Apple Neural Engine).
// Requer o pacote WhisperKit via SPM: https://github.com/argmaxinc/WhisperKit
// Antes de instalado, compila como stub e mostra mensagem de erro na UI.

enum LocalWhisperError: LocalizedError {
    case modelNotLoaded
    case packageNotInstalled

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Local model not loaded. Open Settings → Local AI to download it."
        case .packageNotInstalled:
            return "WhisperKit not installed. In Xcode: File → Add Package Dependencies → https://github.com/argmaxinc/WhisperKit"
        }
    }
}

@MainActor
class LocalWhisperService: ObservableObject {

    static let shared = LocalWhisperService()

    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isReady: Bool = false
    @Published private(set) var loadedModel: LocalWhisperModel? = nil
    @Published private(set) var errorMessage: String? = nil

#if canImport(WhisperKit)
    private var kit: WhisperKit?
#endif

    private init() {}

    // MARK: - Load model (downloads from Hugging Face on first use, then reads from cache)

    func load(model: LocalWhisperModel) async {
#if canImport(WhisperKit)
        guard model != loadedModel || !isReady else { return }

        isLoading = true
        isReady = false
        errorMessage = nil
        loadedModel = nil
        kit = nil

        do {
            // Store models in Application Support/Spit/WhisperModels — accessible within sandbox
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let modelsDir = appSupport.appendingPathComponent("Spit/WhisperModels", isDirectory: true)
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            // Purga de modelos antigos: apaga qualquer modelo em cache que não seja o
            // que vamos usar. Evita acumulação (ex: large-v3, base de versões com
            // seletor de modelo) que enchia o disco e agravava a pressão de memória
            // → Jetsam. Só corre uma vez por sessão (guard).
            purgeOtherModels(keeping: model, in: modelsDir)

            let newKit = try await WhisperKit(
                model: model.rawValue,
                downloadBase: modelsDir,
                verbose: false,
                logLevel: .none,
                prewarm: true
            )
            kit = newKit
            loadedModel = model
            isReady = true
            isLoading = false
            vfLog("LocalWhisperService — model loaded: \(model.rawValue)")
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            vfLog("LocalWhisperService — load error: \(error)")
        }
#else
        errorMessage = "WhisperKit not installed. In Xcode: File → Add Package Dependencies → https://github.com/argmaxinc/WhisperKit"
#endif
    }

    // MARK: - Purga de modelos antigos

    /// Corre no máximo uma vez por sessão.
    private var didPurge = false

    /// Apaga do disco qualquer modelo WhisperKit em cache que não seja `keep`.
    /// O layout do WhisperKit é `<base>/models/argmaxinc/whisperkit-coreml/<modelo>`.
    /// O tokenizer (`models/openai/...`) é pequeno e NÃO é tocado.
    private func purgeOtherModels(keeping keep: LocalWhisperModel, in base: URL) {
        guard !didPurge else { return }
        didPurge = true

        let coremlDir = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: coremlDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            let name = url.lastPathComponent
            // Manter só a pasta do modelo em uso; ignorar ficheiros soltos.
            guard url.hasDirectoryPath, name != keep.rawValue else { continue }
            do {
                try fm.removeItem(at: url)
                vfLog("LocalWhisperService — purgado modelo antigo não usado: '\(name)'")
            } catch {
                vfLog("LocalWhisperService — falha a purgar '\(name)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Unload (memory pressure / sleep)

    func unload() async {
#if canImport(WhisperKit)
        guard isReady else { return }
        kit = nil
        isReady = false
        loadedModel = nil
        vfLog("LocalWhisperService — modelo descarregado (pressão de memória)")
#endif
    }

    // MARK: - Transcribe

    func transcribe(audioURL: URL, language: String, vocabularyHint: String) async throws -> WhisperResult {
#if canImport(WhisperKit)
        guard let kit else { throw LocalWhisperError.modelNotLoaded }

        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.usePrefillPrompt = true
        options.usePrefillCache = true
        if language != "auto", !language.isEmpty {
            options.language = language
        } else {
            // Auto-detect: force Portuguese as default hint since that's the primary use case.
            // WhisperKit still detects the actual language — this just biases the initial token.
            options.language = "pt"
        }
        // vocabularyHint: WhisperKit uses tokenized prompts.
        // TODO: tokenize via kit.tokenizer and assign to options.prompt

        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLang = WhisperResult.localeIdentifier(from: results.first?.language)
        return WhisperResult(text: text, detectedLanguage: detectedLang)
#else
        throw LocalWhisperError.packageNotInstalled
#endif
    }
}
