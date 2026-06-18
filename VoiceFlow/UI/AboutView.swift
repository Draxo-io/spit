import SwiftUI
import AppKit
import StoreKit

// MARK: - AboutView

struct AboutView: View {

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private let build   = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    /// Data/hora em que este binário foi compilado (data de modificação do
    /// executável). Reflete sempre o build atual — usado para distinguir o
    /// build de desenvolvimento local do build do TestFlight.
    private var buildDateString: String? {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM/yyyy HH:mm"
        return fmt.string(from: date)
    }

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

                #if DEBUG
                // Visível apenas no build de desenvolvimento local — quando
                // este badge aparece, NÃO estás no TestFlight; a data confirma
                // qual a versão que estás a testar.
                HStack(spacing: 5) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9))
                    Text("Build de desenvolvimento")
                        .font(.system(size: 10, weight: .semibold))
                    if let d = buildDateString {
                        Text("· \(d)")
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .padding(.top, 2)
                #endif
            }

            Text("AI-powered dictation for macOS.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 10) {
                Link("Website", destination: URL(string: "https://getspit.app")!)
                    .font(.subheadline)

                HStack(spacing: 20) {
                    Link("Privacy", destination: URL(string: "https://getspit.app/privacy")!)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Link("Terms", destination: URL(string: "https://getspit.app/terms")!)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Link("Support", destination: URL(string: "https://getspit.app/support")!)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .padding(.horizontal, 40)

            Text("© 2026 Spit — all rights reserved.")
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
