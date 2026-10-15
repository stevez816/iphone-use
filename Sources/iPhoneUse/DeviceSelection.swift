import Foundation

enum DeviceSelection {
    /// IDs take precedence. Names and prefixes must resolve to exactly one phone.
    static func matches(_ query: String, in devices: [(id: String, name: String)]) -> [String] {
        let q = query.lowercased()
        if let exact = devices.first(where: { $0.id.lowercased() == q }) { return [exact.id] }
        let names = devices.filter { $0.name.lowercased() == q }.map(\.id)
        if !names.isEmpty { return names }
        return devices.filter { $0.id.lowercased().hasPrefix(q) }.map(\.id)
    }
}
