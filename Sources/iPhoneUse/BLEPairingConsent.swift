import AppKit
import CoreBluetooth
import ObjectiveC

/// Compatibility workaround for macOS rejecting a new HID central because no
/// pairing agent handles it. This is private API: validate its ABI at runtime,
/// fail closed when unavailable, and require explicit local consent every time.
final class BLEPairingConsent: NSObject, CBCentralManagerDelegate {
    private let queue: DispatchQueue
    private var agent: NSObject?
    private var requests = PairingRequests()
    private var window = PairingWindow()
    private var targetName = "iPhone"
    private var connector: CBCentralManager?
    private var pairingPeer: CBPeripheral?
    private(set) var status = "unavailable"

    // Main queue only. Request state itself always belongs to the Bluetooth queue.
    private var activePrompt: (token: UUID, alert: NSAlert)?

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        guard connector == nil else { return }
        connector = CBCentralManager(delegate: self, queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func register(with manager: CBCentralManager) {
        let getter = NSSelectorFromString("sharedPairingAgent")
        let setter = NSSelectorFromString("setDelegate:")
        let response = NSSelectorFromString("respondToPairingRequest:type:accept:data:")
        guard Self.hasSignature(manager, getter, result: "@", arguments: ["@", ":"]),
            let candidate = manager.perform(getter)?.takeUnretainedValue() as? NSObject,
            Self.hasSignature(candidate, setter, result: "v", arguments: ["@", ":", "@"]),
            Self.hasSignature(candidate, response, result: "v", arguments: ["@", ":", "@", "q", "B", "@"]),
            Self.hasSignature(candidate, NSSelectorFromString("pairPeer:useMITM:"), result: "v", arguments: ["@", ":", "@", "B"]),
            Self.hasSignature(candidate, NSSelectorFromString("isPeerPaired:"), result: "B", arguments: ["@", ":", "@"])
        else {
            status = "pairing confirmation API unavailable on this macOS version"
            log(status)
            return
        }
        if agent !== candidate {
            agent = candidate
            candidate.perform(setter, with: self)
        }
        status = "ready; open a pairing window for a new iPhone"
        log(status)
    }

    func openWindow(targetName: String) throws {
        guard agent != nil else { throw DeviceError(status) }
        guard requests.pending == nil, pairingPeer == nil else { throw DeviceError("finish the current pairing attempt first") }
        self.targetName = targetName
        window.open()
        status = "pairing window open for \(targetName) (120 seconds); tap this Mac on the iPhone"
        log(status)
        let token = window.token
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.window.token == token else { return }
            if let request = self.requests.reset() { self.dismiss(request.token) }
            self.window.close()
            self.releaseConnection()
            self.status = "pairing window expired; open a new window to retry"
            log(self.status)
        }
    }

    /// macOS 26.1 rejects an unsolicited SMP request even with a registered
    /// pairing delegate. Claim the newly connected central before its encrypted
    /// HID read, so bluetoothd associates the pairing operation with this app.
    /// This starts MITM-protected pairing; it does not accept the consent prompt.
    func connected(_ central: CBPeer) {
        guard let agent, let connector, connector.state == .poweredOn, window.deadline != nil else { return }
        let pairedSelector = NSSelectorFromString("isPeerPaired:")
        typealias IsPaired = @convention(c) (AnyObject, Selector, CBPeer) -> Bool
        let isPaired = unsafeBitCast(agent.method(for: pairedSelector), to: IsPaired.self)
        guard window.claim(central.identifier, isPaired: isPaired(agent, pairedSelector, central)) else { return }
        guard let peer = connector.retrievePeripherals(withIdentifiers: [central.identifier]).first,
            peer.identifier == central.identifier else {
            window.close()
            status = "cannot register the incoming phone for pairing"
            log(status)
            return
        }
        pairingPeer = peer
        status = "registering the incoming phone for pairing"
        log("connecting pairing client to incoming central \(peer.identifier)")
        connector.connect(peer)
        let attempt = window.token
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.window.token == attempt, self.pairingPeer === peer else { return }
            if let request = self.requests.reset() { self.dismiss(request.token) }
            self.window.close()
            self.releaseConnection()
            self.status = "pairing attempt timed out; open a new pairing window to retry"
            log(self.status)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard connector === central else { return }
        if central.state == .poweredOn {
            register(with: central)
        } else {
            if let request = requests.reset() { dismiss(request.token) }
            window.close()
            pairingPeer = nil
            agent = nil
            status = "pairing Bluetooth unavailable (\(central.state.rawValue))"
        }
    }

    // A registered pairing agent receives system connection events on its
    // owning manager. These precede didConnect, which only covers this app's
    // explicit connections. The peripheral-manager callback alone misses them.
    @objc(centralManager:didUpdatePeripheralConnectionState:)
    func centralManager(_ central: CBCentralManager, didUpdatePeripheralConnectionState peripheral: CBPeripheral) {
        guard connector === central else { return }
        let selector = NSSelectorFromString("isConnectedToSystem")
        guard Self.hasSignature(peripheral, selector, result: "B", arguments: ["@", ":"]) else { return }
        typealias Connected = @convention(c) (AnyObject, Selector) -> Bool
        let read = unsafeBitCast(peripheral.method(for: selector), to: Connected.self)
        guard read(peripheral, selector) else { return }
        log("pairing client observed incoming peer \(peripheral.identifier)")
        connected(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connector === central, pairingPeer === peripheral,
            window.permits(peripheral.identifier), let agent else { return }
        status = "requesting pairing; waiting for confirmation"
        log("initiating encrypted pairing through central client for \(peripheral.identifier)")
        let selector = NSSelectorFromString("pairPeer:useMITM:")
        typealias Pair = @convention(c) (AnyObject, Selector, CBPeer, Bool) -> Void
        let pair = unsafeBitCast(agent.method(for: selector), to: Pair.self)
        pair(agent, selector, peripheral, true)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionEnded(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionEnded(central, peripheral: peripheral, error: error)
    }

    private func connectionEnded(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        guard connector === central, pairingPeer === peripheral else { return }
        if let request = requests.finish(peer: peripheral.identifier) { dismiss(request.token) }
        window.close()
        pairingPeer = nil
        status = "pairing connection ended: \(error?.localizedDescription ?? "disconnected")"
        log(status)
    }

    private func releaseConnection() {
        guard let peer = pairingPeer else { return }
        pairingPeer = nil
        connector?.cancelPeripheralConnection(peer)
    }

    /// Called on the Bluetooth queue when the manager loses power/authorization.
    func reset() {
        if let request = requests.reset() { dismiss(request.token) }
        window.close()
        releaseConnection()
        agent = nil
        connector = nil
        status = "Bluetooth unavailable"
    }

    @objc(pairingAgent:peerDidRequestPairing:type:passkey:)
    func pairingRequested(_ agent: NSObject, peer: CBPeer, type: Int, passkey: NSNumber?) {
        queue.async {
            guard self.agent === agent else { return }
            guard self.window.permits(peer.identifier) else {
                self.sendResponse(agent, peer: peer, type: type, accept: false)
                log("declined pairing outside the selected pairing window: \(peer.identifier)")
                return
            }
            switch self.requests.begin(peer: peer.identifier) {
            case .duplicate: return
            case .busy:
                self.sendResponse(agent, peer: peer, type: type, accept: false)
                log("declined concurrent pairing request from \(peer.identifier)")
            case .prompt(let request):
                self.status = "waiting for pairing confirmation"
                log("pairing requested by \(peer.identifier), type \(type), has passkey: \(passkey != nil)")
                DispatchQueue.main.async {
                    self.showPrompt(request, agent: agent, peer: peer, type: type, passkey: passkey)
                }
            }
        }
    }

    private func showPrompt(
        _ request: PairingRequests.Request, agent: NSObject, peer: CBPeer, type: Int, passkey: NSNumber?
    ) {
        guard queue.sync(execute: { requests.pending == request }) else { return }
        let alert = NSAlert()
        alert.messageText = "iPhone Use 蓝牙配对"
        var detail = "仅在你刚刚从 \(targetName) 发起配对时继续。\n配对后还会单独验证手机画面与蓝牙控制的对应关系。"
        if let passkey {
            detail += "\n\n配对码：\(String(format: "%06u", passkey.uint32Value))\n请确认这个号码与目标 iPhone 上的号码一致。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "配对").keyEquivalent = ""
        alert.addButton(withTitle: "取消").keyEquivalent = "\r"
        activePrompt = (request.token, alert)
        let timeout = DispatchWorkItem { [weak self] in
            self?.resolve(request, agent: agent, peer: peer, type: type, accept: false, timedOut: true)
        }
        queue.asyncAfter(deadline: .now() + 25, execute: timeout)
        NSApp.activate(ignoringOtherApps: true)
        let accepted = alert.runModal() == .alertFirstButtonReturn
        timeout.cancel()
        if activePrompt?.token == request.token { activePrompt = nil }
        queue.async {
            self.resolve(request, agent: agent, peer: peer, type: type, accept: accepted)
        }
    }

    private func resolve(
        _ request: PairingRequests.Request, agent: NSObject, peer: CBPeer, type: Int,
        accept: Bool, timedOut: Bool = false
    ) {
        guard requests.resolve(token: request.token) else { return }
        dismiss(request.token)
        status = timedOut ? "pairing confirmation timed out" : (accept ? "pairing in progress" : "pairing cancelled")
        if !accept { window.close() }
        log("pairing response for \(peer.identifier): \(status)")
        sendResponse(agent, peer: peer, type: type, accept: accept)
        if !accept { releaseConnection() }
    }

    private func sendResponse(_ agent: NSObject, peer: CBPeer, type: Int, accept: Bool) {
        let selector = NSSelectorFromString("respondToPairingRequest:type:accept:data:")
        typealias Response = @convention(c) (AnyObject, Selector, CBPeer, Int, Bool, NSDictionary?) -> Void
        let send = unsafeBitCast(agent.method(for: selector), to: Response.self)
        send(agent, selector, peer, type, accept, nil)
    }

    @objc(pairingAgent:peerDidCompletePairing:)
    func pairingCompleted(_ agent: NSObject, peer: CBPeer) {
        queue.async {
            guard self.agent === agent else { return }
            guard self.window.peer == peer.identifier else { return }
            if let request = self.requests.finish(peer: peer.identifier) { self.dismiss(request.token) }
            if self.window.peer == peer.identifier { self.window.close() }
            self.releaseConnection()
            self.status = "paired"
            log("pairing completed for \(peer.identifier)")
        }
    }

    @objc(pairingAgent:peerDidFailToCompletePairing:error:)
    func pairingFailed(_ agent: NSObject, peer: CBPeer, error: NSError) {
        queue.async {
            guard self.agent === agent else { return }
            guard self.window.peer == peer.identifier else { return }
            if let request = self.requests.finish(peer: peer.identifier) { self.dismiss(request.token) }
            if self.window.peer == peer.identifier { self.window.close() }
            self.releaseConnection()
            self.status = "pairing failed: \(error.localizedDescription)"
            log("pairing failed for \(peer.identifier): \(error)")
        }
    }

    private func dismiss(_ token: UUID) {
        DispatchQueue.main.async {
            guard let active = self.activePrompt, active.token == token else { return }
            NSApp.abortModal()
            active.alert.window.close()
        }
    }

    private static func hasSignature(_ object: NSObject, _ selector: Selector, result: String, arguments: [String]) -> Bool {
        guard let cls = object_getClass(object), let method = class_getInstanceMethod(cls, selector),
            method_getNumberOfArguments(method) == arguments.count
        else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return false }
        for (index, expected) in arguments.enumerated() {
            guard let actual = method_copyArgumentType(method, UInt32(index)) else { return false }
            defer { free(actual) }
            guard String(cString: actual) == expected else { return false }
        }
        return true
    }
}
