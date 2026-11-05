import Cocoa

if let code = NativeCommands.handle(Array(CommandLine.arguments.dropFirst())) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
