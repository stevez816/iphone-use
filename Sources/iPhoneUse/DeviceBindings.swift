import Foundation

/// Only verified or explicitly assigned screen/host associations are persisted.
/// Version 1 was an unversioned dictionary and could contain guessed associations.
struct DeviceBindings: Codable {
    private(set) var version = 2
    private(set) var pairings: [String: UUID] = [:]

    init() {}

    init(data: Data) throws {
        let saved = try JSONDecoder().decode(Self.self, from: data)
        guard saved.version == 2,
            Set(saved.pairings.values).count == saved.pairings.count
        else { throw CocoaError(.fileReadCorruptFile) }
        self = saved
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    mutating func forget(_ screenIDs: [String]) {
        for id in screenIDs { pairings[id] = nil }
    }

    mutating func assign(screen: String, host: UUID) {
        pairings = pairings.filter { $0.key != screen && $0.value != host }
        pairings[screen] = host
    }

    /// A single USB screen and a single Bluetooth host are still different identities.
    /// Every new automatic association must pass the same pointer verification.
    mutating func match(
        screens: [String], hosts: [UUID],
        probe: (UUID, [String]) -> String?
    ) -> [String: UUID] {
        let matchedHosts = Set(screens.compactMap { pairings[$0] }.filter(hosts.contains))
        var freeScreens = screens.filter { pairings[$0].map { !hosts.contains($0) } ?? true }
        var found: [String: UUID] = [:]
        for host in hosts where !matchedHosts.contains(host) && !freeScreens.isEmpty {
            guard let screen = probe(host, freeScreens), freeScreens.contains(screen) else { continue }
            assign(screen: screen, host: host)
            found[screen] = host
            freeScreens.removeAll { $0 == screen }
        }
        return found
    }
}
