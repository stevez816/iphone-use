import Foundation

/// The HTTP API. Every route takes an optional `device` (id or name), required only when
/// more than one phone is plugged in. Tap and swipe coordinates are pixels of the full
/// screen, or of a resized screenshot when `width`/`height` or `maxEdge` say so.
enum Routes {
    private static let actions: Set = ["/tap", "/swipe", "/move", "/nudge", "/type", "/key", "/home"]

    static func handle(_ request: HTTPRequest) -> HTTPResponse {
        let body = request.body
        let deviceQuery = (body["device"] as? String) ?? request.query["device"]
        do {
            switch (request.method, request.path) {
            case ("GET", "/"), ("GET", "/status"):
                return .json([
                    "bluetooth": HIDPeripheral.shared.state,
                    "cameraPermission": ScreenCapture.shared.authorization,
                    "pairing": HIDPeripheral.shared.pairingStatus,
                    "bluetoothHosts": HIDPeripheral.shared.hostDiagnostics,
                    "devices": Devices.shared.all().map(\.json),
                    "unmatchedHosts": Devices.shared.unmatchedHosts().map(\.uuidString),
                ])

            case ("GET", "/devices"):
                return .json(["devices": Devices.shared.all().map(\.json)])

            case ("POST", "/bluetooth/pairing"):
                let device = try Devices.shared.find(deviceQuery)
                try HIDPeripheral.shared.openPairingWindow(targetName: device.screen.name)
                return .json(["pairing": HIDPeripheral.shared.pairingStatus])

            case ("POST", "/match"):
                let found = Devices.shared.match(
                    force: (body["force"] as? Bool) ?? false, probe: (body["probe"] as? Bool) ?? false)
                return .json([
                    "matched": found.mapValues(\.uuidString),
                    "devices": Devices.shared.all().map(\.json),
                    "unmatchedHosts": Devices.shared.unmatchedHosts().map(\.uuidString),
                ])

            case ("POST", "/pair"):
                guard let hostString = body["host"] as? String, let host = UUID(uuidString: hostString) else {
                    return .error("host is required (a UUID from unmatchedHosts)")
                }
                try Devices.shared.pair(Devices.shared.find(deviceQuery), host: host)
                return .json(["devices": Devices.shared.all().map(\.json)])

            case ("GET", "/screenshot"):
                let device = try Devices.shared.find(deviceQuery)
                let png = request.query["format"] == "png"
                let maxWidth = request.query["maxWidth"].flatMap(Int.init)
                let maxEdge = request.query["maxEdge"].flatMap(Int.init)
                guard let size = device.screen.size,
                    let data = device.screen.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge)
                else { return .error("no frame yet from \(device.screen.name): unlock it", status: 503) }
                let image = imageSize(size, maxWidth: maxWidth, maxEdge: maxEdge)
                return HTTPResponse(
                    contentType: png ? "image/png" : "image/jpeg",
                    headers: [
                        "X-Device": device.id,
                        "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
                        "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
                    ],
                    body: data)

            default:
                guard request.method == "POST", actions.contains(request.path) else {
                    return .error("not found", status: 404)
                }
            }

            let device = try Devices.shared.find(deviceQuery)
            let reports: [ReportID]
            switch request.path {
            case "/tap", "/swipe": reports = [.absolutePointer, .relativeMouse]
            case "/move": reports = [.absolutePointer]
            case "/nudge": reports = [.relativeMouse]
            case "/type", "/key": reports = [.keyboard]
            default: reports = [.consumer]
            }
            return try Devices.shared.withInput(for: device, requiring: reports) { input in
                switch (request.method, request.path) {
                case ("POST", "/tap"):
                    let (x, y) = try point(body, "x", "y", on: device)
                    try input.tap(x: x, y: y, hold: (body["hold"] as? Double) ?? 0.08)
                case ("POST", "/swipe"):
                    let from = try point(body, "x1", "y1", on: device)
                    let to = try point(body, "x2", "y2", on: device)
                    try input.swipe(from: from, to: to, duration: (body["duration"] as? Double) ?? 0.3)
                case ("POST", "/move"):
                    let (x, y) = try point(body, "x", "y", on: device)
                    try input.move(x: x, y: y)
                case ("POST", "/nudge"):
                    try input.nudge(
                        dx: (body["dx"] as? Int) ?? 0, dy: (body["dy"] as? Int) ?? 0,
                        click: (body["click"] as? Bool) ?? false)
                case ("POST", "/type"):
                    guard let text = body["text"] as? String else { return .error("text is required") }
                    try input.type(text)
                case ("POST", "/key"):
                    guard let key = body["key"] as? String else { return .error("key is required") }
                    try input.key(key, modifiers: (body["modifiers"] as? [String]) ?? [])
                case ("POST", "/home"):
                    try input.consumer(0x0223)
                default:
                    return .error("not found", status: 404)
                }
                return .json(["ok": true, "device": device.id])
            }
        } catch {
            return .error("\(error)")
        }
    }

    private static func imageSize(_ size: CGSize, maxWidth: Int?, maxEdge: Int?) -> (Int, Int) {
        var scale = 1.0
        if let maxWidth { scale = min(scale, Double(maxWidth) / size.width) }
        if let maxEdge { scale = min(scale, Double(maxEdge) / max(size.width, size.height)) }
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Converts coordinates to 0...1 fractions of the phone's screen.
    private static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String, on device: Device
    ) throws -> (Double, Double) {
        guard let x = number(body[xKey]), let y = number(body[yKey]) else {
            throw DeviceError("\(xKey) and \(yKey) are required")
        }
        if (body["fraction"] as? Bool) == true { return (x, y) }
        guard let size = device.screen.size else { throw DeviceError("no frame yet from \(device.screen.name)") }
        var width = Double(size.width)
        var height = Double(size.height)
        if let maxEdge = number(body["maxEdge"]).map(Int.init) {
            let image = imageSize(size, maxWidth: nil, maxEdge: maxEdge)
            width = Double(image.0)
            height = Double(image.1)
        }
        width = number(body["width"]) ?? width
        height = number(body["height"]) ?? height
        return (x / width, y / height)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
