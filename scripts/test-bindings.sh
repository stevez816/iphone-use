#!/bin/zsh
# Works with Command Line Tools alone; XCTest requires a full Xcode installation.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/iPhoneUse/DeviceBindings.swift Tests/DeviceBindings/main.swift -o "$TEST_DIR/binding-tests"
"$TEST_DIR/binding-tests"
swiftc Sources/iPhoneUse/PointerVerification.swift Sources/iPhoneUse/DeviceSelection.swift \
  Sources/iPhoneUse/PairingRequests.swift Tests/MatchingAndPairing/main.swift -o "$TEST_DIR/matching-tests"
"$TEST_DIR/matching-tests"
swiftc Sources/iPhoneUse/Input.swift Sources/iPhoneUse/Keymap.swift Sources/iPhoneUse/HIDReportMap.swift \
  Tests/Input/main.swift -o "$TEST_DIR/input-tests"
"$TEST_DIR/input-tests"
swiftc Sources/iPhoneUse/Devices.swift Sources/iPhoneUse/DeviceBindings.swift \
  Sources/iPhoneUse/DeviceSelection.swift Sources/iPhoneUse/PointerVerification.swift \
  Sources/iPhoneUse/Input.swift Sources/iPhoneUse/Keymap.swift Sources/iPhoneUse/HIDReportMap.swift \
  Tests/Devices/main.swift -o "$TEST_DIR/device-tests"
"$TEST_DIR/device-tests"
