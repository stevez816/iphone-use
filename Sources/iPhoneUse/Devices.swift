import Foundation

/// A phone: its USB screen, and the Bluetooth host that drives it once matched and connected.
struct Device {
    let screen: Screen
    let host: UUID?

    var id: String { screen.id }

    var json: [String: Any] {
        var info: [String: Any] = ["id": id, "name": screen.name, "bluetooth": host != nil]
        if let size = screen.size {
            info["width"] = Int(size.width)
            info["height"] = Int(size.height)
        }
        return info
    }
}

/// Matches each phone's Bluetooth connection to its USB screen. Bluetooth does not say which
/// phone is which, so matching moves the pointer through one connection and looks for the
/// screen where it moved. Matches are saved, so a phone is matched once.
final class Devices {
    static let shared = Devices()

    private let lock = NSLock()
    private var bindings = DeviceBindings()
    private var inputs: [UUID: Input] = [:]
    private var matchPending = false
    private let matchQueue = DispatchQueue(label: "iphone-use.match", attributes: .concurrent)

    private let file: URL

    init(file: URL? = nil) {
        if let file {
            self.file = file
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneUse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.file = directory.appendingPathComponent("pairings.json")
    }

    func start() {
        load()
        ScreenCapture.shared.onScreensChanged = { [weak self] in self?.scheduleMatch() }
        HIDPeripheral.shared.onHostsChanged = { [weak self] in self?.scheduleMatch() }
    }

    func all() -> [Device] {
        let hosts = Set(HIDPeripheral.shared.connectedHosts)
        let pairings = lock.withLock { bindings.pairings }
        return ScreenCapture.shared.all.map { screen in
            Device(screen: screen, host: pairings[screen.id].flatMap { hosts.contains($0) ? $0 : nil })
        }
    }

    /// Connected Bluetooth hosts that no present screen is matched to.
    func unmatchedHosts() -> [UUID] {
        let matched = Set(all().compactMap(\.host))
        return HIDPeripheral.shared.connectedHosts.filter { !matched.contains($0) }
    }

    /// A phone by id, name or id prefix. Without a query there must be exactly one phone.
    func find(_ query: String?) throws -> Device {
        let devices = all()
        if let query, !query.isEmpty {
            let ids = DeviceSelection.matches(query, in: devices.map { ($0.id, $0.screen.name) })
            guard !ids.isEmpty else { throw DeviceError("no phone matches \"\(query)\". \(Self.describe(devices))") }
            guard ids.count == 1 else {
                throw DeviceError("ambiguous device \"\(query)\"; pass its full id. \(Self.describe(devices))")
            }
            return devices.first { $0.id == ids[0] }!
        }
        guard !devices.isEmpty else {
            throw DeviceError("no iPhone screen: plug the iPhone in over USB and unlock it")
        }
        guard devices.count == 1 else {
            throw DeviceError("\(devices.count) phones are connected, pass device. \(Self.describe(devices))")
        }
        return devices[0]
    }

    /// Readers may control different phones concurrently. Rematching/manual binding
    /// uses a barrier, so an in-flight gesture cannot be redirected by a rematch.
    func withInput<T>(for device: Device, requiring reports: [ReportID], _ action: (Input) throws -> T) throws -> T {
        if try find(device.id).host == nil { match() }
        return try matchQueue.sync {
            guard let host = try find(device.id).host else {
                if unmatchedHosts().isEmpty {
                    throw DeviceError(
                        "\(device.screen.name) has no verified Bluetooth connection: pair \"\(HIDPeripheral.shared.localName)\" in its Bluetooth settings, enable AssistiveTouch, then POST /match"
                    )
                }
                throw DeviceError(
                    "could not verify which Bluetooth connection is \(device.screen.name): unlock it, enable AssistiveTouch, keep its screen still, then POST /match"
                )
            }
            try HIDPeripheral.shared.require(reports, from: host)
            return try action(input(for: host))
        }
    }

    func input(for host: UUID) -> Input {
        lock.withLock {
            if let input = inputs[host] { return input }
            let input = Input(host: host)
            inputs[host] = input
            return input
        }
    }

    func pair(_ device: Device, host: UUID) throws {
        try matchQueue.sync(flags: .barrier) {
            _ = try find(device.id)
            guard HIDPeripheral.shared.connectedHosts.contains(host) else {
                throw DeviceError("Bluetooth host is not connected; pair the phone in Bluetooth settings first")
            }
            lock.withLock {
                bindings.assign(screen: device.id, host: host)
                saveLocked()
            }
        }
    }

    /// Matches unmatched hosts to unmatched screens and waits for the result.
    /// `force` revokes existing matches before testing, including when no new match is found.
    /// `probe` is retained for API compatibility; new matches are always verified.
    @discardableResult
    func match(force: Bool = false, probe: Bool = false) -> [String: UUID] {
        matchQueue.sync(flags: .barrier) { runMatch(force: force) }
    }

    // MARK: Matching

    private func scheduleMatch() {
        let alreadyPending = lock.withLock {
            defer { matchPending = true }
            return matchPending
        }
        guard !alreadyPending else { return }
        matchQueue.asyncAfter(deadline: .now() + 1.5, flags: .barrier) {
            self.lock.withLock { self.matchPending = false }
            self.runMatch(force: false)
        }
    }

    @discardableResult
    private func runMatch(force: Bool) -> [String: UUID] {
        let screens = ScreenCapture.shared.all
        let hosts = HIDPeripheral.shared.connectedHosts
        if force {
            lock.withLock {
                bindings.forget(screens.map(\.id))
                saveLocked()
            }
        }
        var updated = lock.withLock { bindings }
        let found = updated.match(screens: screens.map(\.id), hosts: hosts) { host, candidates in
            probe(host, among: screens.filter { candidates.contains($0.id) })?.id
        }
        if !found.isEmpty {
            lock.withLock {
                bindings = updated
                saveLocked()
            }
        }
        for (id, host) in found {
            log("matched \(screens.first { $0.id == id }?.name ?? id) to bluetooth host \(host)")
        }
        return found
    }

    /// Move only the pointer, never click while discovering a phone's identity.
    private func probe(_ host: UUID, among screens: [Screen]) -> Screen? {
        guard (try? HIDPeripheral.shared.require([.absolutePointer], from: host)) != nil else { return nil }
        let input = input(for: host)
        var frames = screens.map { _ in [[UInt8]]() }
        for position in PointerVerification.positions {
            do { try input.move(x: position.x, y: position.y) }
            catch { log("pointer probe interrupted: \(error)"); return nil }
            Thread.sleep(forTimeInterval: 0.6)
            for (index, screen) in screens.enumerated() {
                if let pixels = screen.thumbnail(width: PointerVerification.width, height: PointerVerification.height) {
                    frames[index].append(pixels)
                }
            }
        }
        let verified = screens.enumerated().compactMap { index, screen -> Screen? in
            let score = PointerVerification.score(frames[index])
            log("probe \(host): \(screen.name)=\(score.map(String.init) ?? "unverified")")
            return score == nil ? nil : screen
        }
        // Ambiguity is a failed match even if one screen has a stronger signal.
        guard verified.count == 1,
            HIDPeripheral.shared.connectedHosts.contains(host),
            ScreenCapture.shared.all.contains(where: { $0.id == verified[0].id })
        else { return nil }
        return verified[0]
    }

    // MARK: Saved matches

    /// Caller holds lock. Atomic writes keep interrupted saves from corrupting associations.
    private func saveLocked() {
        do {
            try bindings.encoded().write(to: file, options: .atomic)
        } catch {
            log("could not save device bindings: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            let saved = try DeviceBindings(data: data)
            lock.withLock { bindings = saved }
        } catch {
            log("ignoring legacy or invalid device bindings; pointer verification is required")
        }
    }

    private static func describe(_ devices: [Device]) -> String {
        guard !devices.isEmpty else { return "No phones are plugged in." }
        return "Phones: " + devices.map { "\($0.screen.name) (\($0.id))" }.joined(separator: ", ")
    }
}

struct DeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
