import AppKit
import CoreGraphics
import Foundation

// MARK: - SystemAudioManager
// Pausa/retoma a reprodução de media (Spotify, Apple Music, browsers, etc.)
// enquanto o Spit está a gravar ou a ler em voz alta.
//
// Mecanismo: envia a tecla play/pause (NX_KEYTYPE_PLAY = 16) via NSEvent — o
// mesmo sinal que o teclado físico emite. Antes de pausar, consulta o
// MediaRemote framework (privado, carregado dinamicamente) para verificar se
// há algo a tocar — evita iniciar reprodução quando nada estava a tocar.
//
// Thread safety: chamar sempre da main thread.

final class SystemAudioManager {

    static let shared = SystemAudioManager()
    private init() {}

    // MARK: - State

    /// true enquanto nós fomos responsáveis por pausar a media.
    private var didPauseMedia = false
    /// Prevents two concurrent MediaRemote queries (e.g. from two overlapping startDictation calls).
    private var isPausing = false

    // MARK: - MediaRemote (private framework — loaded once)

    private typealias MRIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias MRGetNowPlayingPIDFunc = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

    private lazy var mrBundle: CFBundle? = {
        CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        )
    }()

    private lazy var mrIsPlayingFn: MRIsPlayingFunc? = {
        guard let bundle = mrBundle,
              let ptr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
              ) else { return nil }
        return unsafeBitCast(ptr, to: MRIsPlayingFunc.self)
    }()

    /// Returns the PID of the app currently registered as "now playing".
    /// Returns 0 when nothing has ever played in this session — mais fiável que
    /// `isPlaying` em cenários Bluetooth, onde este último mente (retorna false
    /// mesmo com música a tocar). Se PID > 0, há um app registado como media
    /// controller — é seguro enviar play/pause sem o sistema abrir Apple Music.
    private lazy var mrGetNowPlayingPIDFn: MRGetNowPlayingPIDFunc? = {
        guard let bundle = mrBundle,
              let ptr = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteGetNowPlayingApplicationPID" as CFString
              ) else { return nil }
        return unsafeBitCast(ptr, to: MRGetNowPlayingPIDFunc.self)
    }()

    /// Verifica se existe um app registado como now-playing controller.
    /// Timeout de 800ms — se o MediaRemote demorar, assume 0 (safer: não envia key).
    private func nowPlayingPID() async -> Int32 {
        guard let fn = mrGetNowPlayingPIDFn else { return 0 }
        return await withCheckedContinuation { continuation in
            var resumed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: 0)
            }
            fn(.main) { pid in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: pid)
            }
        }
    }

    // MARK: - Public

    /// Pausa a media activa.
    ///
    /// Estratégia:
    ///   1. Verifica se existe um now-playing PID. Se não houver (0), NÃO envia
    ///      play/pause — caso contrário o macOS captura o sinal e abre o Apple
    ///      Music (app por defeito do media key).
    ///   2. Se houver PID > 0, envia play/pause. Isto cobre o caso Bluetooth
    ///      onde `isPlaying` retorna false erradamente mas o PID está correcto.
    ///   3. `didPauseMedia` garante que só retomamos se fomos nós a pausar.
    func pauseMedia() async {
        guard !didPauseMedia, !isPausing else { return }
        isPausing = true
        defer { isPausing = false }

        let pid = await nowPlayingPID()
        guard pid > 0 else {
            vfLog("SystemAudioManager — no now-playing app (PID=0), skip pause to avoid launching Apple Music")
            return
        }

        sendPlayPauseKey()
        didPauseMedia = true
        vfLog("SystemAudioManager — media paused ▶→⏸ (pid:\(pid))")
    }

    /// Retoma a media que foi pausada por pauseMedia(). Não faz nada se não pausámos.
    func resumeMedia() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        sendPlayPauseKey()
        vfLog("SystemAudioManager — media resumed ⏸→▶")
    }

    // MARK: - Media Key

    private func sendPlayPauseKey() {
        let keyCode: Int = 16  // NX_KEYTYPE_PLAY

        for keyDown in [true, false] {
            let flags: Int = keyDown ? 0xa00 : 0xb00
            let data1: Int = (keyCode << 16) | flags

            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else {
                vfLog("SystemAudioManager — failed to create media key event")
                continue
            }

            // Inject at HID level (same as physical F8 keypress) so Chrome,
            // browsers and other apps that only listen to hardware media keys
            // also receive it. cgSessionEventTap is delivered higher up the
            // chain and Chrome/web players don't see it — confirmed in
            // production with Google Music in Chrome (2026-04-27).
            event.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
        }
    }
}
