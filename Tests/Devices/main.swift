import Foundation

func log(_ message: String) {}

// Only the hardware edges are doubled. Exercise the production matcher, storage,
// input sender and concurrency barriers without using real Bluetooth or cameras.
final class HIDPeripheral {
    static let shared = HIDPeripheral()
    let localName = "Test HID"
    var onHostsChanged: (() -> Void)?
    var connectedHosts: [UUID] = []
    var allowed: [ReportID] = [.keyboard, .absolutePointer, .relativeMouse, .consumer]
    var pointer: [UUID: (x: Double, y: Double)] = [:]
    var clickHosts: [UUID] = []

    func require(_ reports: [ReportID], from host: UUID) throws {
        guard connectedHosts.contains(host), reports.allSatisfy(allowed.contains) else {
            throw DeviceError("host or report unavailable")
        }
    }
    func send(_ id: ReportID, _ bytes: [UInt8], to host: UUID) throws {
        try require([id], from: host)
        if id == .absolutePointer {
            pointer[host] = (Double(Int(bytes[1]) + (Int(bytes[2]) << 8)) / 32767,
                Double(Int(bytes[3]) + (Int(bytes[4]) << 8)) / 32767)
        }
        if id == .relativeMouse, bytes[0] != 0 { clickHosts.append(host) }
    }
}

final class Screen {
    let id: String
    let name: String
    let host: UUID
    var showPointer = true
    let size: CGSize? = CGSize(width: 1170, height: 2532)
    init(id: String, name: String, host: UUID) { self.id = id; self.name = name; self.host = host }
    func thumbnail(width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 90, count: width * height)
        guard showPointer, let point = HIDPeripheral.shared.pointer[host] else { return pixels }
        let cx = Int(point.x * Double(width)), cy = Int(point.y * Double(height))
        for y in max(0, cy - 2)...min(height - 1, cy + 2) {
            for x in max(0, cx - 2)...min(width - 1, cx + 2) { pixels[y * width + x] = 240 }
        }
        return pixels
    }
}

final class ScreenCapture {
    static let shared = ScreenCapture()
    var onScreensChanged: (() -> Void)?
    var all: [Screen] = []
}

func expectError(_ body: () throws -> Void) {
    do { try body() } catch { return }
    fatalError("expected rejection")
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("bindings.json")
let unrelated = UUID(), correct = UUID()
try JSONSerialization.data(withJSONObject: ["target-phone": unrelated.uuidString]).write(to: file)
let screen = Screen(id: "target-phone", name: "target-phone", host: correct)
ScreenCapture.shared.all = [screen]
let hid = HIDPeripheral.shared
hid.connectedHosts = [unrelated]
let devices = Devices(file: file)
devices.start()
precondition(try! devices.find("target-phone").host == nil)
expectError {
    try devices.withInput(for: devices.find("target-phone"), requiring: [.absolutePointer, .relativeMouse]) {
        try $0.tap(x: 0.5, y: 0.5)
    }
}
precondition(hid.clickHosts.isEmpty)
print("PASS: legacy wrong binding and unrelated live host cannot receive a tap")

hid.connectedHosts = [unrelated, correct]
precondition(devices.match() == ["target-phone": correct])
try devices.withInput(for: devices.find("target-phone"), requiring: [.absolutePointer, .relativeMouse]) {
    try $0.tap(x: 0.5, y: 0.5, hold: 0)
}
precondition(hid.clickHosts == [correct])
print("PASS: actual pointer verification routes the tap only to target-phone")

hid.allowed = [.absolutePointer]
var called = false
expectError {
    try devices.withInput(for: devices.find("target-phone"), requiring: [.absolutePointer, .relativeMouse]) { _ in called = true }
}
precondition(!called)
hid.allowed = [.keyboard, .absolutePointer, .relativeMouse, .consumer]
print("PASS: missing click channel rejects the entire action")

screen.showPointer = false
precondition(devices.match(force: true).isEmpty)
let persisted = try DeviceBindings(data: Data(contentsOf: file))
precondition(persisted.pairings.isEmpty)
precondition(try! devices.find("target-phone").host == nil)
expectError { try devices.pair(devices.find("target-phone"), host: UUID()) }
print("PASS: failed forced rematch persists removal; offline manual binding is rejected")

try devices.pair(devices.find("target-phone"), host: correct)
let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let actionDone = DispatchSemaphore(value: 0), rematchDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    try! devices.withInput(for: devices.find("target-phone"), requiring: [.relativeMouse]) { _ in
        started.signal()
        release.wait()
    }
    actionDone.signal()
}
precondition(started.wait(timeout: .now() + 2) == .success)
DispatchQueue.global().async { devices.match(force: true); rematchDone.signal() }
precondition(rematchDone.wait(timeout: .now() + 0.1) == .timedOut)
release.signal()
precondition(actionDone.wait(timeout: .now() + 2) == .success)
precondition(rematchDone.wait(timeout: .now() + 10) == .success)
precondition(try! devices.find("target-phone").host == nil)
print("PASS: rematching waits for the current action instead of changing its target")
