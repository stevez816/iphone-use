import Foundation

/// A user opens this window for one new phone. Existing bonds and subsequent
/// connection-parameter updates must not start another pairing operation.
struct PairingWindow {
    private(set) var token: UUID?
    private(set) var deadline: Date?
    private(set) var peer: UUID?

    mutating func open(now: Date = Date()) {
        token = UUID()
        deadline = now.addingTimeInterval(120)
        peer = nil
    }

    mutating func claim(_ candidate: UUID, isPaired: Bool, now: Date = Date()) -> Bool {
        guard let deadline, now < deadline, peer == nil, !isPaired else { return false }
        peer = candidate
        return true
    }

    func permits(_ candidate: UUID, now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now < deadline && peer == candidate
    }

    mutating func close() { token = nil; deadline = nil; peer = nil }
}

/// Serialised by the Bluetooth queue. Tokens prevent a dismissed/expired dialog
/// from responding to a later request, or overwriting a pairing failure.
struct PairingRequests {
    struct Request: Equatable {
        let token = UUID()
        let peer: UUID
    }

    enum Start {
        case prompt(Request)
        case duplicate
        case busy
    }

    private(set) var pending: Request?

    mutating func begin(peer: UUID) -> Start {
        if let pending { return pending.peer == peer ? .duplicate : .busy }
        let request = Request(peer: peer)
        pending = request
        return .prompt(request)
    }

    mutating func resolve(token: UUID) -> Bool {
        guard pending?.token == token else { return false }
        pending = nil
        return true
    }

    @discardableResult
    mutating func finish(peer: UUID) -> Request? {
        guard pending?.peer == peer else { return nil }
        return reset()
    }

    mutating func reset() -> Request? {
        defer { pending = nil }
        return pending
    }
}
