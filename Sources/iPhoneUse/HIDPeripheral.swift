import CoreBluetooth
import Foundation

/// The Mac as a BLE keyboard + pointer (HID over GATT). Classic Bluetooth HID is out:
/// bluetoothd owns L2CAP PSM 17 and 19 on current macOS.
final class HIDPeripheral: NSObject, CBPeripheralManagerDelegate {
    static let shared = HIDPeripheral()

    let localName = "iPhone Use"

    private let queue = DispatchQueue(label: "iphone-use.bluetooth")
    private var manager: CBPeripheralManager!
    private var servicesToAdd: [CBMutableService] = []
    private var addingService: CBMutableService?
    private var published = false
    private lazy var pairingConsent = BLEPairingConsent(queue: queue)

    var pairingStatus: String { queue.sync { pairingConsent.status } }

    func openPairingWindow(targetName: String) throws {
        try queue.sync {
            guard manager?.state == .poweredOn, published else { throw DeviceError("Bluetooth HID service is not ready") }
            try pairingConsent.openWindow(targetName: targetName)
        }
    }

    private var inputs: [ReportID: CBMutableCharacteristic] = [:]
    private var keyboardOutput: CBMutableCharacteristic!
    private var controlPoint: CBMutableCharacteristic!
    private var protocolMode: CBMutableCharacteristic!
    private var batteryLevel: CBMutableCharacteristic!
    private var serviceChanged: CBMutableCharacteristic!

    private var centrals: [UUID: CBCentral] = [:]
    private var subscriptions: [UUID: Set<ObjectIdentifier>] = [:]
    private var serviceChangedSent = Set<UUID>()
    private var outbox: [(CBMutableCharacteristic, Data, [CBCentral]?)] = []

    private var stateDescription = "starting"
    var state: String {
        if CBManager.authorization == .notDetermined { return "waiting for Bluetooth permission" }
        return queue.sync { stateDescription }
    }

    /// Report subscriptions are more useful than a generic "connected" flag when
    /// pairing completed but iOS has not discovered the mouse/keyboard channels.
    var hostDiagnostics: [[String: Any]] {
        queue.sync {
            hostsWithInput.sorted { $0.uuidString < $1.uuidString }.map { host in
                ["id": host.uuidString, "reports": inputs.compactMap { id, characteristic in
                    subscriptions[host]?.contains(ObjectIdentifier(characteristic)) == true ? String(describing: id) : nil
                }.sorted()]
            }
        }
    }

    /// Called on the Bluetooth queue when a phone starts or stops listening for input.
    var onHostsChanged: (() -> Void)?

    func start() {
        queue.async {
            self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        }
    }

    /// Phones subscribed to at least one input report.
    var connectedHosts: [UUID] {
        queue.sync { hostsWithInput }
    }

    private var hostsWithInput: [UUID] {
        let ids = Set(inputs.values.map(ObjectIdentifier.init))
        return subscriptions.filter { !$0.value.isDisjoint(with: ids) }.map(\.key)
    }

    func require(_ reports: [ReportID], from host: UUID) throws {
        try queue.sync { try requireOnQueue(reports, from: host) }
    }

    private func requireOnQueue(_ reports: [ReportID], from host: UUID) throws {
        guard manager?.state == .poweredOn, published, centrals[host] != nil else {
            throw DeviceError("Bluetooth host \(host) disconnected; reconnect the iPhone")
        }
        for report in reports {
            guard let characteristic = inputs[report],
                subscriptions[host]?.contains(ObjectIdentifier(characteristic)) == true else {
                throw DeviceError("Bluetooth host \(host) is not ready for \(report); reconnect the iPhone and enable AssistiveTouch")
            }
        }
    }

    func send(_ id: ReportID, _ bytes: [UInt8], to host: UUID) throws {
        try queue.sync {
            try requireOnQueue([id], from: host)
            outbox.append((inputs[id]!, Data(bytes), [centrals[host]!]))
            drain()
        }
    }

    // MARK: GATT database

    private static func sig(_ short: String) -> CBUUID {
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private func buildServices() -> [CBMutableService] {
        serviceChanged = CBMutableCharacteristic(
            type: CBUUID(string: "2A05"), properties: [.indicate], value: nil, permissions: [.readable])
        let gatt = CBMutableService(type: Self.sig("1801"), primary: true)
        gatt.characteristics = [serviceChanged]

        let info = CBMutableCharacteristic(
            type: CBUUID(string: "2A4A"), properties: [.read],
            value: Data([0x11, 0x01, 0x00, 0x02]), permissions: [.readable])
        let reportMap = CBMutableCharacteristic(
            type: CBUUID(string: "2A4B"), properties: [.read],
            value: Data(HIDReportMap.descriptor), permissions: [.readEncryptionRequired])
        controlPoint = CBMutableCharacteristic(
            type: CBUUID(string: "2A4C"), properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeEncryptionRequired])
        protocolMode = CBMutableCharacteristic(
            type: CBUUID(string: "2A4E"), properties: [.read, .writeWithoutResponse],
            value: nil, permissions: [.readable, .writeable])

        var characteristics: [CBMutableCharacteristic] = [info, reportMap, controlPoint, protocolMode]
        for id in [ReportID.keyboard, .absolutePointer, .relativeMouse, .consumer] {
            let report = CBMutableCharacteristic(
                type: CBUUID(string: "2A4D"), properties: [.read, .notify],
                value: nil, permissions: [.readEncryptionRequired])
            report.descriptors = [CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([id.rawValue, 1]))]
            inputs[id] = report
            characteristics.append(report)
        }
        keyboardOutput = CBMutableCharacteristic(
            type: CBUUID(string: "2A4D"), properties: [.read, .write, .writeWithoutResponse],
            value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        keyboardOutput.descriptors = [
            CBMutableDescriptor(type: CBUUID(string: "2908"), value: Data([ReportID.keyboard.rawValue, 2]))
        ]
        characteristics.append(keyboardOutput)

        let hid = CBMutableService(type: Self.sig("1812"), primary: true)
        hid.characteristics = characteristics

        let device = CBMutableService(type: Self.sig("180A"), primary: true)
        device.characteristics = [
            CBMutableCharacteristic(
                type: CBUUID(string: "2A29"), properties: [.read],
                value: Data("iPhone Use".utf8), permissions: [.readable]),
            CBMutableCharacteristic(
                type: CBUUID(string: "2A50"), properties: [.read],
                value: Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]), permissions: [.readable]),
        ]

        batteryLevel = CBMutableCharacteristic(
            type: CBUUID(string: "2A19"), properties: [.read, .notify], value: nil, permissions: [.readable])
        let battery = CBMutableService(type: Self.sig("180F"), primary: true)
        battery.characteristics = [batteryLevel]

        return [gatt, hid, device, battery]
    }

    private func addNextService() {
        guard !servicesToAdd.isEmpty else {
            published = true
            advertise()
            return
        }
        let next = servicesToAdd.removeFirst()
        addingService = next
        manager.add(next)
    }

    private func advertise() {
        guard published, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
        ])
    }

    // MARK: CBPeripheralManagerDelegate

    // Private delegate callback, verified on macOS 26.1. Unlike subscriptions,
    // this arrives before the encrypted HID read that triggers first pairing.
    @objc(peripheralManager:didUpdateConnectionParameters:interval:latency:supervisionTimeout:)
    func peripheralManager(
        _ peripheral: CBPeripheralManager, didUpdateConnectionParameters central: CBCentral,
        interval: NSNumber?, latency: NSNumber?, supervisionTimeout: NSNumber?
    ) {
        log("incoming central \(central.identifier) connection parameters updated")
        pairingConsent.connected(central)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("bluetooth state \(peripheral.state.rawValue) auth \(CBManager.authorization.rawValue)")
        // A radio reset invalidates every subscription and queued input. Never
        // replay old taps or retain a false connection after it comes back.
        centrals.removeAll()
        subscriptions.removeAll()
        serviceChangedSent.removeAll()
        outbox.removeAll()
        inputs.removeAll()
        servicesToAdd.removeAll()
        addingService = nil
        published = false
        pairingConsent.reset()
        switch peripheral.state {
        case .poweredOn:
            pairingConsent.start()
            stateDescription = "powered on"
            peripheral.removeAllServices()
            servicesToAdd = buildServices()
            addNextService()
        case .unauthorized:
            stateDescription = "bluetooth not allowed (System Settings > Privacy & Security > Bluetooth)"
        case .poweredOff:
            stateDescription = "bluetooth off"
        default:
            stateDescription = "bluetooth unavailable (\(peripheral.state.rawValue))"
        }
        onHostsChanged?()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral.state == .poweredOn, addingService === service else { return }
        addingService = nil
        if let error {
            stateDescription = "failed to add \(service.uuid): \(error.localizedDescription)"
            log(stateDescription)
            return
        }
        log("added service \(service.uuid)")
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral.state == .poweredOn, published else { return }
        if let error, (error as? CBError)?.code != .alreadyAdvertising {
            stateDescription = "advertising failed: \(error.localizedDescription)"
        } else {
            stateDescription = "advertising as \(localName)"
        }
        log(stateDescription)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let value: Data
        switch request.characteristic.uuid {
        case CBUUID(string: "2A4E"): value = Data([0x01])
        case CBUUID(string: "2A19"): value = Data([100])
        case CBUUID(string: "2A4D"): value = Data(count: reportLength(request.characteristic))
        default:
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            remember(request.central)
            if request.characteristic.uuid == controlPoint.uuid {
                log("control point write \(request.value.map { [UInt8]($0) } ?? []) from \(request.central.identifier)")
                recoverStaleCacheIfNeeded(request.central)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        remember(central)
        subscriptions[central.identifier, default: []].insert(ObjectIdentifier(characteristic))
        log("subscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        if let (id, input) = inputs.first(where: { $0.value === characteristic }) {
            outbox.append((input, Data(count: Self.length(id)), [central]))
            drain()
            hostsChanged()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscriptions[central.identifier]?.remove(ObjectIdentifier(characteristic))
        outbox.removeAll { item in
            item.0 === characteristic && item.2?.contains(where: { $0.identifier == central.identifier }) == true
        }
        if subscriptions[central.identifier]?.isEmpty != false {
            subscriptions[central.identifier] = nil
            centrals[central.identifier] = nil
            serviceChangedSent.remove(central.identifier)
        }
        log("unsubscribe \(characteristic.uuid) \(describe(characteristic)) from \(central.identifier)")
        hostsChanged()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    // MARK: Helpers

    /// Keeps advertising while phones are connected so more can pair.
    private func hostsChanged() {
        let count = hostsWithInput.count
        stateDescription = count == 0 ? "advertising as \(localName)" : "\(count) connected, advertising as \(localName)"
        advertise()
        onHostsChanged?()
    }

    private func drain() {
        while let (characteristic, data, targets) = outbox.first {
            guard manager.state == .poweredOn, published else { outbox.removeAll(); return }
            guard let targets, !targets.isEmpty, targets.allSatisfy({
                subscriptions[$0.identifier]?.contains(ObjectIdentifier(characteristic)) == true
            }) else { outbox.removeFirst(); continue }
            guard manager.updateValue(data, for: characteristic, onSubscribedCentrals: targets) else { return }
            outbox.removeFirst()
        }
    }

    private func remember(_ central: CBCentral) {
        centrals[central.identifier] = central
    }

    /// A bonded host that trusts a stale cache writes the Control Point but never subscribes.
    /// Service Changed makes it rediscover.
    private func recoverStaleCacheIfNeeded(_ central: CBCentral) {
        let subscribed = subscriptions[central.identifier] ?? []
        let hasInput = !subscribed.isDisjoint(with: inputs.values.map(ObjectIdentifier.init))
        guard !hasInput, subscribed.contains(ObjectIdentifier(serviceChanged)),
            !serviceChangedSent.contains(central.identifier)
        else { return }
        serviceChangedSent.insert(central.identifier)
        log("stale cache on \(central.identifier), indicating Service Changed")
        outbox.insert((serviceChanged, Data([0x10, 0x00, 0xFF, 0xFF]), [central]), at: 0)
        drain()
    }

    private func reportLength(_ characteristic: CBCharacteristic) -> Int {
        if characteristic === keyboardOutput { return 1 }
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return Self.length(id) }
        return 0
    }

    private static func length(_ id: ReportID) -> Int {
        switch id {
        case .keyboard: 8
        case .absolutePointer: 5
        case .relativeMouse: 4
        case .consumer: 2
        }
    }

    private func describe(_ characteristic: CBCharacteristic) -> String {
        if let id = inputs.first(where: { $0.value === characteristic })?.key { return "(\(id))" }
        return ""
    }
}
