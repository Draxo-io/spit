import AppKit

// Entry point puro AppKit — sem SwiftUI App lifecycle.
// Garante que o Carbon event loop é correctamente inicializado
// (necessário para RegisterEventHotKey).

vfLog("=== Spit STARTING ===")
let app = NSApplication.shared
vfLog("NSApplication created")
let delegate = AppDelegate()
vfLog("AppDelegate created")
app.delegate = delegate
vfLog("Delegate set — calling app.run()")
app.run()
