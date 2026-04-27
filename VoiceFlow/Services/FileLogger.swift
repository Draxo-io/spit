import Foundation

// MARK: - FileLogger
// Logger que escreve direto para ficheiro — garante output visível
// (NSLog no macOS moderno vai para os_log e não aparece em stderr)

final class FileLogger {
    static let shared = FileLogger()
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.voiceflow.logger")
    let logURL: URL

    private init() {
        // Use ~/Library/Logs/Spit/ — the Apple-recommended location for app logs.
        // Works whether the app is sandboxed or not (NSTemporaryDirectory() varies
        // depending on sandbox state, which made the log file hard to find).
        let fm = FileManager.default
        let logsDir: URL
        if let homeLogs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Spit", isDirectory: true) {
            try? fm.createDirectory(at: homeLogs, withIntermediateDirectories: true)
            logsDir = homeLogs
        } else {
            // Fallback (shouldn't happen on macOS)
            logsDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        let url = logsDir.appendingPathComponent("spit-debug.log")
        self.logURL = url
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        // Rotate: keep last 300 KB so crash context from the previous session
        // is always readable, but the file never grows unbounded.
        let maxBytes = 300_000
        let keepBytes = 150_000
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxBytes,
           let data = try? Data(contentsOf: url) {
            let trimmed = data.suffix(keepBytes)
            try? trimmed.write(to: url)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        // Write a startup marker so we can tell runs apart.
        if let data = "\n── [FileLogger] start @ \(ISO8601DateFormatter().string(from: Date())) → \(url.path) ──\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(filename):\(line)] \(message)\n"
        // Synchronous write — ensures ordering and that nothing is lost
        // even when the process is killed or a Task hangs before returning.
        guard let data = entry.data(using: .utf8) else { return }
        fileHandle?.write(data)
        fileHandle?.synchronizeFile()
    }
}

func vfLog(_ message: String, file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, file: file, line: line)
}
