import Foundation

// MARK: - FileLogger
// Logger que escreve direto para ficheiro — garante output visível
// (NSLog no macOS moderno vai para os_log e não aparece em stderr)

final class FileLogger {
    static let shared = FileLogger()
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.voiceflow.logger")

    private init() {
        let logPath = "/tmp/voiceflow-debug.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(filename):\(line)] \(message)\n"
        queue.async { [weak self] in
            if let data = entry.data(using: .utf8) {
                self?.fileHandle?.write(data)
                self?.fileHandle?.synchronizeFile()
            }
        }
    }
}

func vfLog(_ message: String, file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, file: file, line: line)
}
