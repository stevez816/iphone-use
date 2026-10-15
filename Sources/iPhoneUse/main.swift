import AppKit
import Foundation
import os

private let appLogger = Logger(subsystem: "ai.new-wave.iphone-use", category: "app")

func log(_ message: String) {
    appLogger.info("\(message, privacy: .public)")
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

if CommandLine.arguments.dropFirst().first == "mcp" {
    MCPServer.run()
}

let port = UInt16(ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] ?? "") ?? 7390

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Devices.shared.start()
HIDPeripheral.shared.start()
ScreenCapture.shared.start()
let server = HTTPServer(port: port, handler: Routes.handle)
do {
    try server.start()
    log("listening on http://127.0.0.1:\(port)")
} catch {
    log("http failed: \(error)")
    exit(1)
}

app.run()
