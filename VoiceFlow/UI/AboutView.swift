import SwiftUI
import AppKit

// MARK: - AboutView

struct AboutView: View {

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            // Icon + name
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            VStack(spacing: 4) {
                Text("Spit")
                    .font(.largeTitle.bold())
                Text("Version \(version) (\(build))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Text("AI-powered dictation for macOS.\nPowered by OpenAI Whisper.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 10) {
                Link("Website — getspit.app", destination: URL(string: "https://getspit.app")!)
                    .font(.subheadline)

                Link("Privacy Policy", destination: URL(string: "https://getspit.app/privacy")!)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link("Support", destination: URL(string: "https://getspit.app/support")!)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .padding(.horizontal, 40)

            Text("© 2025 Rafael Lopes. All rights reserved.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(width: 320)
    }
}

// MARK: - AboutWindowController

class AboutWindowController: NSWindowController {

    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Spit"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
