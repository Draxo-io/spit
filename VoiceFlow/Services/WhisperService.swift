import Foundation

// MARK: - WhisperService
// Envia áudio para a OpenAI Whisper API e devolve o texto transcrito.
// Suporta chave do utilizador (BYOK) e chave do developer (free trial).

enum WhisperError: LocalizedError {
    case noAPIKey
    case fileTooLarge
    case networkError(Error)
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Go to Settings to add your OpenAI key."
        case .fileTooLarge:
            return "Audio too long (max 25 MB). Try a shorter dictation."
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        case .apiError(let msg):
            return "API error: \(msg)"
        case .invalidResponse:
            return "Invalid API response."
        }
    }
}

// Standard JSON response
struct WhisperResponse: Codable {
    let text: String
}

// Verbose JSON response — includes detected language (used when language = "auto")
struct WhisperVerboseResponse: Codable {
    let text: String
    let language: String?  // e.g. "portuguese", "english", "spanish"
}

// Result returned to callers — text + detected language as a locale identifier (e.g. "pt", "en")
struct WhisperResult {
    let text: String
    let detectedLanguage: String?  // nil if unknown or fixed language was specified

    /// Maps Whisper's full language name to an AppSettings-compatible locale string
    static func localeIdentifier(from whisperLanguage: String?) -> String? {
        guard let lang = whisperLanguage?.lowercased() else { return nil }
        let map: [String: String] = [
            "portuguese": "pt",
            "english":    "en",
            "spanish":    "es",
            "french":     "fr",
            "german":     "de",
            "italian":    "it",
            "dutch":      "nl",
            "russian":    "ru",
            "chinese":    "zh",
            "japanese":   "ja",
            "korean":     "ko",
            "arabic":     "ar",
            "hindi":      "hi",
            "turkish":    "tr",
            "polish":     "pl",
            "swedish":    "sv",
            "norwegian":  "no",
            "danish":     "da",
            "finnish":    "fi",
        ]
        return map[lang]
    }
}

struct WhisperAPIError: Codable {
    struct ErrorDetail: Codable {
        let message: String
        let type: String?
    }
    let error: ErrorDetail
}

class WhisperService {

    private let devAPIKey: String? = nil  // Preencher antes de distribuir
    private let apiURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let maxFileSizeBytes = 25 * 1024 * 1024  // 25 MB — limite Whisper

    // MARK: - Transcrição com Vocabulário (método principal)
    // Usa verbose_json quando language="auto" para obter idioma detectado.
    // Retorna WhisperResult com texto e idioma detectado.

    func transcribe(audioURL: URL, language: String, apiKey: String, vocabularyHint: String) async throws -> WhisperResult {
        let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if fileSize > maxFileSizeBytes { throw WhisperError.fileTooLarge }

        let boundary = "Spit-\(UUID().uuidString)"
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        let crlf = "\r\n"

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("whisper-1\(crlf)".data(using: .utf8)!)

        if !language.isEmpty && language != "auto" {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(language)\(crlf)".data(using: .utf8)!)
        }

        if !vocabularyHint.isEmpty {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(vocabularyHint)\(crlf)".data(using: .utf8)!)
        }

        // Use verbose_json when language is auto — response includes detected language field
        let useVerbose = language == "auto"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("\(useVerbose ? "verbose_json" : "json")\(crlf)".data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WhisperError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let apiError = try? JSONDecoder().decode(WhisperAPIError.self, from: data) {
                throw WhisperError.apiError(apiError.error.message)
            }
            throw WhisperError.apiError("HTTP \(httpResponse.statusCode)")
        }

        try? FileManager.default.removeItem(at: audioURL)

        if useVerbose {
            guard let result = try? JSONDecoder().decode(WhisperVerboseResponse.self, from: data) else {
                throw WhisperError.invalidResponse
            }
            let detectedLocale = WhisperResult.localeIdentifier(from: result.language)
            vfLog("Whisper verbose: language='\(result.language ?? "?")' → locale='\(detectedLocale ?? "?")'")
            return WhisperResult(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                detectedLanguage: detectedLocale
            )
        } else {
            guard let result = try? JSONDecoder().decode(WhisperResponse.self, from: data) else {
                throw WhisperError.invalidResponse
            }
            return WhisperResult(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                detectedLanguage: nil
            )
        }
    }

    // MARK: - Construir Body Multipart (usado pela transcrição simples legada)

    private func buildMultipartBody(audioURL: URL, language: String, boundary: String) throws -> Data {
        var body = Data()
        let crlf = "\r\n"

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(audioData)
        body.append(crlf.data(using: .utf8)!)

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("whisper-1\(crlf)".data(using: .utf8)!)

        if !language.isEmpty && language != "auto" {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(language)\(crlf)".data(using: .utf8)!)
        }

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append("json\(crlf)".data(using: .utf8)!)

        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        return body
    }
}
