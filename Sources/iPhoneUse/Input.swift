import Foundation

/// Turns taps, swipes and text into HID reports for one phone. Each phone has its own
/// serial queue, so gestures never interleave and phones work in parallel.
final class Input {
    let host: UUID

    private let queue: DispatchQueue
    private let hid = HIDPeripheral.shared
    private var buttons: UInt8 = 0

    init(host: UUID) {
        self.host = host
        queue = DispatchQueue(label: "iphone-use.input.\(host)")
    }

    /// Seconds between reports. BLE connection intervals are ~15-30 ms.
    var step: TimeInterval = 0.03

    /// Coordinates are fractions of the screen, 0...1 from the top-left corner.
    func tap(x: Double, y: Double, hold: TimeInterval = 0.08) throws {
        try perform {
            defer { buttons = 0 }
            try pointer(x, y)
            pause(step * 2)
            try button(down: true)
            pause(hold)
            try button(down: false)
            pause(step)
        }
    }

    func swipe(from: (Double, Double), to: (Double, Double), duration: TimeInterval) throws {
        try perform {
            defer { buttons = 0 }
            let steps = max(2, Int(duration / step))
            try pointer(from.0, from.1)
            pause(step * 2)
            try button(down: true)
            pause(step)
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                try pointer(from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t)
                pause(duration / Double(steps))
            }
            try button(down: false)
            pause(step)
        }
    }

    func move(x: Double, y: Double) throws {
        try perform {
            defer { buttons = 0 }
            try pointer(x, y)
            pause(step)
        }
    }

    /// Relative mouse, for testing hosts that ignore the absolute pointer.
    func nudge(dx: Int, dy: Int, click: Bool) throws {
        try perform {
            var remainingX = dx
            var remainingY = dy
            while remainingX != 0 || remainingY != 0 {
                let sx = max(-127, min(127, remainingX))
                let sy = max(-127, min(127, remainingY))
                try hid.send(.relativeMouse, [0, UInt8(bitPattern: Int8(sx)), UInt8(bitPattern: Int8(sy)), 0], to: host)
                remainingX -= sx
                remainingY -= sy
                pause(step)
            }
            if click {
                try hid.send(.relativeMouse, [1, 0, 0, 0], to: host)
                pause(0.08)
                try hid.send(.relativeMouse, [0, 0, 0, 0], to: host)
                pause(step)
            }
        }
    }

    func type(_ text: String) throws {
        let strokes = try text.map { character -> Keymap.Stroke in
            guard let stroke = Keymap.stroke(for: character) else { throw InputError.untypeable(character) }
            return stroke
        }
        try perform {
            for stroke in strokes {
                try press(stroke)
            }
        }
    }

    /// A named key with optional modifiers, e.g. key("h", modifiers: ["cmd"]).
    func key(_ name: String, modifiers: [String]) throws {
        guard let code = Keymap.named[name.lowercased()] ?? (name.count == 1 ? Keymap.stroke(for: Character(name))?.code : nil)
        else { throw InputError.unknownKey(name) }
        var mask: UInt8 = 0
        for modifier in modifiers {
            guard let bit = Keymap.modifiers[modifier.lowercased()] else { throw InputError.unknownKey(modifier) }
            mask |= bit
        }
        try perform { try press(Keymap.Stroke(code: code, modifiers: mask)) }
    }

    func consumer(_ usage: UInt16) throws {
        try perform {
            try hid.send(.consumer, [UInt8(usage & 0xFF), UInt8(usage >> 8)], to: host)
            pause(0.08)
            try hid.send(.consumer, [0, 0], to: host)
            pause(step)
        }
    }

    private func press(_ stroke: Keymap.Stroke) throws {
        if stroke.modifiers != 0 {
            try hid.send(.keyboard, [stroke.modifiers, 0, 0, 0, 0, 0, 0, 0], to: host)
            pause(step)
        }
        try hid.send(.keyboard, [stroke.modifiers, 0, stroke.code, 0, 0, 0, 0, 0], to: host)
        pause(step)
        try hid.send(.keyboard, [stroke.modifiers, 0, 0, 0, 0, 0, 0, 0], to: host)
        pause(step)
        if stroke.modifiers != 0 {
            try hid.send(.keyboard, [0, 0, 0, 0, 0, 0, 0, 0], to: host)
            pause(step)
        }
    }

    /// iOS positions the pointer from the absolute report but ignores its buttons,
    /// so clicks go through the relative mouse.
    private func pointer(_ x: Double, _ y: Double) throws {
        let max = Double(HIDReportMap.absoluteMax)
        let px = UInt16(Swift.max(0, Swift.min(max, (x * max).rounded())))
        let py = UInt16(Swift.max(0, Swift.min(max, (y * max).rounded())))
        let report = [buttons, UInt8(px & 0xFF), UInt8(px >> 8), UInt8(py & 0xFF), UInt8(py >> 8)]
        try hid.send(.absolutePointer, report, to: host)
    }

    private func button(down: Bool) throws {
        buttons = down ? 1 : 0
        try hid.send(.relativeMouse, [buttons, 0, 0, 0], to: host)
    }

    /// Best-effort releases prevent a partially delivered gesture from leaving a
    /// button/key held when only one of the phone's report channels disappears.
    private func perform(_ action: () throws -> Void) throws {
        try queue.sync {
            do { try action() }
            catch {
                buttons = 0
                try? hid.send(.relativeMouse, [0, 0, 0, 0], to: host)
                try? hid.send(.keyboard, Array(repeating: 0, count: 8), to: host)
                try? hid.send(.consumer, [0, 0], to: host)
                throw error
            }
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    enum InputError: Error, CustomStringConvertible {
        case untypeable(Character)
        case unknownKey(String)

        var description: String {
            switch self {
            case .untypeable(let c): "cannot type \(String(reflecting: c)) with a US keyboard"
            case .unknownKey(let k): "unknown key \(k)"
            }
        }
    }
}
