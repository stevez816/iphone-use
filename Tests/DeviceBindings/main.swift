import Foundation

func expectTrue(_ condition: @autoclosure () -> Bool) { precondition(condition()) }
func expectNil<T>(_ value: T?) { precondition(value == nil) }
func expectEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left == right) }
func expectThrowsError<T>(_ body: @autoclosure () throws -> T) {
    do { _ = try body() } catch { return }
    preconditionFailure("Expected an error")
}

final class DeviceBindingsTests {
    func testOneScreenAndUnrelatedHostAreNotAutomaticallyBound() {
        var bindings = DeviceBindings()
        let host = UUID()
        var probed = false
        let found = bindings.match(screens: ["target-phone"], hosts: [host]) { candidate, screens in
            expectEqual(candidate, host)
            expectEqual(screens, ["target-phone"])
            probed = true
            return nil
        }
        expectTrue(probed)
        expectTrue(found.isEmpty)
        expectNil(bindings.pairings["target-phone"])
    }

    func testOnlyTheHostWhosePointerAppearsIsBound() {
        var bindings = DeviceBindings()
        let other = UUID(), target = UUID()
        let found = bindings.match(screens: ["target-phone"], hosts: [other, target]) { host, _ in
            host == target ? "target-phone" : nil
        }
        expectEqual(found, ["target-phone": target])
        expectEqual(bindings.pairings, ["target-phone": target])
    }

    func testFailedForcedRematchRevokesAndPersistsOldBinding() throws {
        var bindings = DeviceBindings()
        let host = UUID()
        bindings.assign(screen: "target-phone", host: host)
        bindings.forget(["target-phone"])
        let found = bindings.match(screens: ["target-phone"], hosts: [host]) { _, _ in nil }
        expectTrue(found.isEmpty)
        let restored = try DeviceBindings(data: bindings.encoded())
        expectTrue(restored.pairings.isEmpty)
    }

    func testLegacyGuessedBindingsAreNotTrusted() throws {
        let data = try JSONSerialization.data(withJSONObject: ["target-phone": UUID().uuidString])
        expectThrowsError(try DeviceBindings(data: data))
    }

    func testConfirmedBindingsSurviveRestart() throws {
        var bindings = DeviceBindings()
        bindings.assign(screen: "target-phone", host: UUID())
        let restored = try DeviceBindings(data: bindings.encoded())
        expectEqual(restored.pairings, bindings.pairings)
    }

    func testHostCannotRemainBoundToTwoScreens() {
        var bindings = DeviceBindings()
        let host = UUID()
        bindings.assign(screen: "old phone", host: host)
        bindings.assign(screen: "target-phone", host: host)
        expectEqual(bindings.pairings, ["target-phone": host])
    }

    func testProbeCannotBindAScreenOutsideTheCandidates() {
        var bindings = DeviceBindings()
        let found = bindings.match(screens: ["target-phone"], hosts: [UUID()]) { _, _ in "another screen" }
        expectTrue(found.isEmpty)
        expectTrue(bindings.pairings.isEmpty)
    }
}

let tests = DeviceBindingsTests()
tests.testOneScreenAndUnrelatedHostAreNotAutomaticallyBound()
tests.testOnlyTheHostWhosePointerAppearsIsBound()
try tests.testFailedForcedRematchRevokesAndPersistsOldBinding()
try tests.testLegacyGuessedBindingsAreNotTrusted()
try tests.testConfirmedBindingsSurviveRestart()
tests.testHostCannotRemainBoundToTwoScreens()
tests.testProbeCannotBindAScreenOutsideTheCandidates()
print("PASS: 7 device-binding regression tests")
