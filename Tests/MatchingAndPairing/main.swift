import Foundation

var passed = 0
func check(_ name: String, _ body: () -> Bool) {
    precondition(body(), name)
    passed += 1
}

func frame(at position: (x: Double, y: Double)) -> [UInt8] {
    var pixels = [UInt8](repeating: 90, count: PointerVerification.width * PointerVerification.height)
    let cx = Int(position.x * Double(PointerVerification.width))
    let cy = Int(position.y * Double(PointerVerification.height))
    for y in (cy - 2)...(cy + 2) {
        for x in (cx - 2)...(cx + 2) { pixels[y * PointerVerification.width + x] = 240 }
    }
    return pixels
}

let path = PointerVerification.positions.map(frame)
check("repeatable pointer path is verified") { PointerVerification.score(path) != nil }
check("stale/static capture never matches") {
    PointerVerification.score(Array(repeating: path[0], count: 4)) == nil
}
check("single A/B movement is insufficient") { PointerVerification.score(Array(path.prefix(2))) == nil }
check("short/missing frames fail closed") {
    PointerVerification.score([[0], path[1], path[2], path[3]]) == nil
}
check("moving pointer on an animated screen is ambiguous") {
    var animated = path
    for index in 0..<animated.count {
        for y in 25..<50 {
            for x in 5..<25 { animated[index][y * 90 + x] = UInt8(index * 60) }
        }
    }
    return PointerVerification.score(animated) == nil
}
check("unrelated changes at two locations do not complete the path") {
    PointerVerification.score([path[0], path[1], path[1], path[1]]) == nil
}
check("returning to a different screen is rejected") {
    var different = path
    for y in 63..<69 { for x in 28..<34 { different[3][y * 90 + x] = 0 } }
    return PointerVerification.score(different) == nil
}
check("clock changes do not prevent a clean match") {
    var clock = path
    for i in 0..<4 { for x in 0..<10 { clock[i][x] = UInt8(i * 60) } }
    return PointerVerification.score(clock) != nil
}

let devices = [(id: "ABC-111", name: "iPhone"), (id: "ABC-222", name: "iPhone"), (id: "DEF-333", name: "Target iPhone")]
check("duplicate names stay ambiguous") { DeviceSelection.matches("iphone", in: devices).count == 2 }
check("duplicate prefixes stay ambiguous") { DeviceSelection.matches("abc", in: devices).count == 2 }
check("full ID takes precedence") { DeviceSelection.matches("abc-222", in: devices) == ["ABC-222"] }
check("unique name resolves correctly") { DeviceSelection.matches("target iphone", in: devices) == ["DEF-333"] }

let peer = UUID(), other = UUID()
var requests = PairingRequests()
func begin(_ peer: UUID) -> PairingRequests.Request {
    guard case .prompt(let request) = requests.begin(peer: peer) else { fatalError("expected new prompt") }
    return request
}
let first = begin(peer)
check("same peer cannot stack dialogs") { if case .duplicate = requests.begin(peer: peer) { return true }; return false }
check("another peer cannot replace pending consent") { if case .busy = requests.begin(peer: other) { return requests.pending == first }; return false }
check("one consent response per request") { requests.resolve(token: first.token) && !requests.resolve(token: first.token) }
let second = begin(peer)
check("late response cannot confirm a new request") { !requests.resolve(token: first.token) && requests.pending == second }
check("unrelated failure preserves current prompt") { requests.finish(peer: other) == nil && requests.pending == second }
check("failure suppresses late dialog response") { requests.finish(peer: peer) == second && !requests.resolve(token: second.token) }
let third = begin(peer)
check("radio reset invalidates consent") { requests.reset() == third && !requests.resolve(token: third.token) }

var window = PairingWindow()
let now = Date(timeIntervalSince1970: 1000)
check("a closed window never initiates pairing") { !window.claim(peer, isPaired: false, now: now) }
window.open(now: now)
check("existing bonds do not consume a new-phone pairing window") {
    !window.claim(other, isPaired: true, now: now) && window.peer == nil
}
check("only one new central can claim the window") {
    window.claim(peer, isPaired: false, now: now) && !window.claim(other, isPaired: false, now: now)
}
check("connection updates do not repeat pairing") { !window.claim(peer, isPaired: false, now: now) }
check("only the claimed peer may request consent") {
    window.permits(peer, now: now) && !window.permits(other, now: now)
}
check("an expired window cannot grant consent") { !window.permits(peer, now: now.addingTimeInterval(120)) }
window.close()
check("closing a window discards its peer") { window.peer == nil && !window.permits(peer, now: now) }
window.open(now: now)
check("expired discovery cannot initiate pairing") { !window.claim(peer, isPaired: false, now: now.addingTimeInterval(121)) }
let oldWindow = window.token
window.close()
window.open(now: now)
check("an old connection timeout cannot expire a later pairing attempt") { window.token != oldWindow }

print("PASS: \(passed) pointer, device selection and pairing lifecycle regression tests")
