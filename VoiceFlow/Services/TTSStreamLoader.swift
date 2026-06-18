import Foundation
import AVFoundation

// MARK: - TTSStreamLoader
//
// Enables progressive streaming playback of TTS audio.
// Instead of waiting for the full MP3 file to download, AVPlayer starts playing
// as soon as the first chunks arrive (~100-200 ms vs ~800-1500 ms).
//
// How it works:
//   1. AVPlayer is given a synthetic URL with scheme "spittts://"
//   2. AVAssetResourceLoaderDelegate intercepts it and starts the real HTTP download
//   3. As bytes arrive, they are fed to AVPlayer in real-time
//   4. AVPlayer starts playing after it has buffered ~1-2 seconds of audio
//
// Usage:
//   let loader = TTSStreamLoader(request: urlRequest)
//   let asset  = AVURLAsset(url: loader.assetURL)
//   asset.resourceLoader.setDelegate(loader, queue: .main)
//   let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
//   player.play()

private let kSpitTTSScheme = "spittts"

@MainActor
final class TTSStreamLoader: NSObject {

    // MARK: - Public

    /// Synthetic URL that triggers AVAssetResourceLoaderDelegate interception.
    let assetURL: URL

    /// Called on the main thread when the download fails before or during playback.
    var onError: ((Error) -> Void)?

    // MARK: - Private state

    private let realRequest: URLRequest
    private var downloadTask: Task<Void, Never>?

    private var receivedData  = Data()
    private var contentLength = Int64(-1)   // -1 = unknown (server didn't send Content-Length)
    private var isComplete    = false

    private var pendingRequests: [AVAssetResourceLoadingRequest] = []

    private static var counter = 0

    // MARK: - Init

    init(request: URLRequest) {
        self.realRequest = request
        TTSStreamLoader.counter += 1
        // Unique synthetic URL so each instance gets its own loader
        self.assetURL = URL(string: "\(kSpitTTSScheme)://stream/\(TTSStreamLoader.counter)")!
        super.init()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    // MARK: - Download

    private func startDownload() {
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: realRequest)

                guard let http = response as? HTTPURLResponse else {
                    throw TTSError.invalidResponse
                }
                switch http.statusCode {
                case 200: break
                case 401: throw TTSError.unauthorized
                case 402: throw TTSError.limitReached
                default:  throw TTSError.apiError("HTTP \(http.statusCode)")
                }

                if let cl = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }) {
                    self.contentLength = cl
                }

                var buffer = Data()
                buffer.reserveCapacity(8192)

                for try await byte in bytes {
                    buffer.append(byte)
                    // Flush every 4 KB — AVPlayer starts playing after ~2-3 flushes (~12 KB ≈ 0.75 s @ 128 kbps)
                    if buffer.count >= 4096 {
                        self.receivedData.append(buffer)
                        buffer.removeAll(keepingCapacity: true)
                        self.processPendingRequests()
                    }
                }
                // Final flush
                if !buffer.isEmpty {
                    self.receivedData.append(buffer)
                }
                self.isComplete = true
                self.processPendingRequests()

            } catch is CancellationError {
                // Cancelled intentionally — no error to propagate
            } catch {
                self.isComplete = true
                for req in self.pendingRequests { req.finishLoading(with: error) }
                self.pendingRequests.removeAll()
                self.onError?(error)
            }
        }
    }

    // MARK: - Serve pending AVPlayer requests

    private func processPendingRequests() {
        for request in pendingRequests {
            fillContentInfo(request)
            fillData(request)
        }
        pendingRequests.removeAll { $0.isFinished }
    }

    private func fillContentInfo(_ request: AVAssetResourceLoadingRequest) {
        guard let info = request.contentInformationRequest else { return }
        info.contentType = "public.mp3"
        info.isByteRangeAccessSupported = false
        // Report known length; if unknown, report current received size (will grow)
        info.contentLength = contentLength > 0 ? contentLength : Int64(receivedData.count)
    }

    private func fillData(_ request: AVAssetResourceLoadingRequest) {
        guard let dataReq = request.dataRequest else { return }
        let startOffset = Int(dataReq.currentOffset)
        guard startOffset <= receivedData.count else { return }

        let slice = receivedData.subdata(in: startOffset..<receivedData.count)
        if !slice.isEmpty {
            dataReq.respond(with: slice)
        }

        if isComplete && dataReq.currentOffset >= Int64(receivedData.count) {
            request.finishLoading()
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension TTSStreamLoader: AVAssetResourceLoaderDelegate {

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingRequests.append(loadingRequest)
            if self.downloadTask == nil {
                self.startDownload()
            } else {
                self.processPendingRequests()
            }
        }
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        Task { @MainActor [weak self] in
            self?.pendingRequests.removeAll { $0 === loadingRequest }
        }
    }
}
