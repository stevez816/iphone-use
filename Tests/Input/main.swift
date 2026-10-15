import Foundation

/// Transport double: these tests never access Bluetooth or any physical phone.
final class HIDPeripheral {
    static let shared = HIDPeripheral()
    struct Report { let id: ReportID; let bytes: [UInt8]; let host: UUID }
    var reports: [Report] = []
    var failAt: Int?
    var attempts = 0
    struct Disconnected: Error {}
    func send(_ id: ReportID, _ bytes: [UInt8], to host: UUID) throws {
        attempts += 1
        if attempts == failAt { throw Disconnected() }
        reports.append(Report(id: id, bytes: bytes, host: host))
    }
    func reset(failAt: Int? = nil) { reports = []; attempts = 0; self.failAt = failAt }
}

let transport = HIDPeripheral.shared
let host = UUID()
let input = Input(host: host)
input.step = 0.001
try input.tap(x: 0.5, y: 0.25, hold: 0)
precondition(transport.reports.map(\.id) == [.absolutePointer, .relativeMouse, .relativeMouse])
precondition(transport.reports.allSatisfy { $0.host == host })
precondition(transport.reports[1].bytes == [1, 0, 0, 0] && transport.reports[2].bytes == [0, 0, 0, 0])
print("PASS: tap positions and clicks only its selected host")

transport.reset(failAt: 3)
do {
    try input.swipe(from: (0.2, 0.3), to: (0.8, 0.7), duration: 0.004)
    fatalError("disconnect must propagate")
} catch is HIDPeripheral.Disconnected {}
precondition(transport.reports.contains { $0.id == .relativeMouse && $0.bytes == [0, 0, 0, 0] })
transport.reset()
try input.move(x: 0.2, y: 0.3)
precondition(transport.reports[0].bytes[0] == 0)
print("PASS: mid-gesture disconnect fails and releases held buttons")

transport.reset(failAt: 1)
do { try input.key("a", modifiers: []); fatalError("disconnect must propagate") }
catch is HIDPeripheral.Disconnected {}
print("PASS: keyboard transport failure reaches caller")

transport.reset()
do { try input.key("not-a-real-key", modifiers: []); fatalError("invalid key must fail") }
catch is Input.InputError {}
precondition(transport.reports.isEmpty)
print("PASS: invalid key fails without sending input or crashing")
