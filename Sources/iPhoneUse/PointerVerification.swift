import Foundation

/// Matching requires a repeatable A → B → C → A pointer path on a quiet screen.
/// One arbitrary frame change is not evidence that a Bluetooth host owns a screen.
enum PointerVerification {
    static let width = 90
    static let height = 195
    static let positions: [(x: Double, y: Double)] = [
        (0.3, 0.35), (0.7, 0.5), (0.35, 0.7), (0.3, 0.35),
    ]

    static func score(_ frames: [[UInt8]]) -> Int? {
        guard frames.count == positions.count,
            frames.allSatisfy({ $0.count == width * height }) else { return nil }
        var weakest = Int.max
        for index in 1..<frames.count {
            let p = frames[index - 1], q = frames[index]
            let from = positions[index - 1], to = positions[index]
            var leaving = 0, arriving = 0, noise = 0
            for y in 0..<height {
                for x in 0..<width where abs(Int(p[y * width + x]) - Int(q[y * width + x])) > 12 {
                    if near(x, y, from) { leaving += 1 }
                    else if near(x, y, to) { arriving += 1 }
                    else if y > height / 10, y < height * 95 / 100 { noise += 1 }
                }
            }
            let signal = min(leaving, arriving)
            guard signal >= 3, noise <= max(12, signal) else { return nil }
            weakest = min(weakest, signal)
        }
        // Returning to A should restore all three pointer regions, not leave an
        // animation or unrelated screen transition mistaken for a moving pointer.
        var residual = 0
        for y in 0..<height {
            for x in 0..<width where positions.contains(where: { near(x, y, $0) }) {
                if abs(Int(frames[0][y * width + x]) - Int(frames[3][y * width + x])) > 12 {
                    residual += 1
                }
            }
        }
        guard residual <= max(3, weakest / 3) else { return nil }
        return weakest
    }

    private static func near(_ x: Int, _ y: Int, _ point: (x: Double, y: Double)) -> Bool {
        abs(x - Int(point.x * Double(width))) <= 7 && abs(y - Int(point.y * Double(height))) <= 7
    }
}
