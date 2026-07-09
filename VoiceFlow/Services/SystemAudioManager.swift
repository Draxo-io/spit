import AppKit
import CoreAudio
import CoreGraphics
import Foundation

// MARK: - SystemAudioManager
// Pausa/retoma a reprodução de media (Spotify, Apple Music, browsers, etc.)
// enquanto o Spit está a gravar ou a ler em voz alta.
//
// Mecanismo: envia a tecla play/pause (NX_KEYTYPE_PLAY = 16) via CGEvent ao
// nível HID — o mesmo sinal que a tecla física F8/⏯ emite.
//
// Detecção de áudio activo:
//   1. Apple Events (NSAppleScript) — pergunta directamente "player state" ao
//      Spotify e ao Music quando estão em execução. É um pull em tempo real do
//      estado verdadeiro, fiável independentemente do que aconteceu antes.
//   2. CoreAudio kAudioDevicePropertyDeviceIsRunningSomewhere — fallback para
//      apps sem AppleScript de media (browsers, web players, etc.).
//
// Problema resolvido: kAudioDevicePropertyDeviceIsRunningSomewhere retorna true
// mesmo quando o Spotify/Chrome tem o dispositivo registado mas com media
// PAUSADA (mantêm o I/O proc activo para retoma rápida). Sem confirmar o estado
// real do player, o Spit interpretava "dispositivo activo" como "media a tocar"
// e enviava a key — iniciando media que estava pausada pelo user.
//
// Por que Apple Events e não DistributedNotificationCenter: o Spotify desktop
// recente já NÃO posta "com.spotify.client.PlaybackStateChanged" no macOS, por
// isso a abordagem de notificações deixava o estado eternamente desconhecido e
// o bug persistia. MRMediaRemote (API privada) está fora por causa da App Store.
// Apple Events é a única via pública e fiável — requer o entitlement
// com.apple.security.automation.apple-events + NSAppleEventsUsageDescription, e
// o macOS pede consentimento de Automação ao utilizador na primeira query.
//
// Trade-off aceite: web players (YouTube Music, Google Music em Chrome) não têm
// AppleScript de media → caem no fallback CoreAudio best-effort, que não
// distingue pausa de reprodução. Aceite — iniciar media pausada de um player
// desktop é o caso comum e está resolvido.
//
// Thread safety: chamar sempre da main thread.

final class SystemAudioManager {

    static let shared = SystemAudioManager()

    // MARK: - State

    /// true enquanto nós fomos responsáveis por pausar a media.
    private var didPauseMedia = false
    /// Prevents two concurrent pause calls (e.g. from two overlapping startDictation calls).
    private var isPausing = false

    private init() {}

    // MARK: - Public

    /// Pausa a media activa se o dispositivo de saída estiver a produzir áudio.
    /// `didPauseMedia` garante que só retomamos se fomos nós a pausar.
    func pauseMedia() async {
        guard !didPauseMedia, !isPausing else { return }
        isPausing = true
        defer { isPausing = false }

        guard isOutputDeviceActive() else {
            vfLog("SystemAudioManager — output silent → skip (no music)")
            return
        }

        sendPlayPauseKey()
        didPauseMedia = true
        vfLog("SystemAudioManager — media paused ▶→⏸ (CoreAudio: output active)")
    }

    /// Returns true if the default output device is actively producing audio.
    ///
    /// Strategy:
    ///   1. kAudioDevicePropertyDeviceIsRunningSomewhere — fast exit if nothing at all.
    ///      NOTE: this is true even for PAUSED media (I/O proc stays registered for quick
    ///      resume), so it's only used as a cheap first gate, not the final decision.
    ///   2. Apple Events — pull real player state from Spotify, Music, QuickTime Player.
    ///   3. Browser/unknown fallback — use kAudioDevicePropertyDeviceIsRunning (audio
    ///      samples actually flowing) instead of DeviceIsRunningSomewhere (I/O proc
    ///      registered). This correctly returns false for paused browser video.
    private func isOutputDeviceActive() -> Bool {
        // Get the default output device ID
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &devAddr, 0, nil, &size, &deviceID
        )
        guard devStatus == noErr, deviceID != 0 else {
            vfLog("SystemAudioManager — could not get default output device (status:\(devStatus))")
            return false
        }

        // Stage 1: quick check — is any process using this device at all?
        var isRunningSomewhere: UInt32 = 0
        var rsSize = UInt32(MemoryLayout<UInt32>.size)
        var rsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let rsStatus = AudioObjectGetPropertyData(deviceID, &rsAddr, 0, nil, &rsSize, &isRunningSomewhere)
        guard rsStatus == noErr else {
            vfLog("SystemAudioManager — could not query device-is-running-somewhere (status:\(rsStatus))")
            return false
        }
        guard isRunningSomewhere != 0 else { return false }

        // Stage 2: Apple Events — pull real play/pause state from known desktop players.
        let spotify   = isPlayerPlaying(appName: "Spotify",          bundleID: "com.spotify.client")
        let music     = isPlayerPlaying(appName: "Music",            bundleID: "com.apple.Music")
        let quicktime = isQuickTimePlayerPlaying()

        // Any confirmed-playing player → send pause key.
        if spotify == true || music == true || quicktime == true { return true }

        // A known player is running but PAUSED (and no other is playing) →
        // the CoreAudio "device running somewhere" is just its residual I/O proc.
        // Sending the key would resume manually-paused media — skip it.
        if spotify == false || music == false || quicktime == false {
            vfLog("SystemAudioManager — desktop player paused (Spotify:\(String(describing: spotify)) Music:\(String(describing: music)) QT:\(String(describing: quicktime))) → skip key")
            return false
        }

        // Stage 3: No known desktop player confirmed via Apple Events.
        // Source may be a browser/web player, OR our own AVAudioEngine (TTS output).
        // We cannot reliably distinguish:
        //   • browser audio actually playing
        //   • Spotify Web / YouTube paused but Chrome keeping audio context alive
        //     (DeviceIsRunning=1 even while paused — confirmed 2026-06-23)
        //   • Spit's own TTS AVAudioEngine making DeviceIsRunning=1
        // Conservative choice: skip the key. Starting paused Spotify Web or toggling
        // our own TTS is worse than missing a browser auto-pause. Fix: 2026-06-23.
        vfLog("SystemAudioManager — no confirmed desktop player (browser/web audio ambiguous) → skip key")
        return false
    }

    /// Queries QuickTime Player for play state via Apple Events.
    /// Returns nil if QT is not running or has no open documents.
    private func isQuickTimePlayerPlaying() -> Bool? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.QuickTimePlayerX"
        }) else { return nil }
        let source = """
        tell application "QuickTime Player"
            if (count of documents) is 0 then return false
            rate of first document is not 0
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            vfLog("SystemAudioManager — QuickTime Player Apple Events query failed: \(err[NSAppleScript.errorNumber] ?? err)")
            return nil
        }
        return result.booleanValue
    }

    /// Pergunta a um player (via Apple Events) se está a reproduzir.
    /// Retorna nil se o app não está em execução, não suporta a query, ou a
    /// permissão de Automação ainda não foi concedida. Só envia o evento quando
    /// o app já corre — nunca o lança.
    private func isPlayerPlaying(appName: String, bundleID: String) -> Bool? {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == bundleID
        }) else { return nil }

        let source = "tell application \"\(appName)\" to player state is playing"
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            vfLog("SystemAudioManager — \(appName) Apple Events query failed: \(errorInfo[NSAppleScript.errorNumber] ?? errorInfo)")
            return nil
        }
        return result.booleanValue
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
