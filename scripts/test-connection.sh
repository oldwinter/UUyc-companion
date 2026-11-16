#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc Sources/UUDisplay/UUConnectionState.swift tests/connection-main.swift -o "$TEST_DIR/connection-tests"
"$TEST_DIR/connection-tests"

swiftc Sources/UUDisplay/UUConnectionState.swift Sources/UUDisplay/UUMonitor.swift Sources/UUDisplay/PowerAssertion.swift tests/monitor-main.swift -o "$TEST_DIR/monitor-tests"
"$TEST_DIR/monitor-tests"

swiftc Sources/UUDisplay/PhysicalDisplays.swift Sources/UUDisplay/Log.swift Sources/UUDisplay/Config.swift tests/physical-main.swift -o "$TEST_DIR/physical-tests"
"$TEST_DIR/physical-tests"

swiftc Sources/UUDisplay/Config.swift tests/config-main.swift -o "$TEST_DIR/config-tests"
"$TEST_DIR/config-tests"

swiftc Sources/UUDisplay/UUReader.swift tests/reader-main.swift -o "$TEST_DIR/reader-tests"
"$TEST_DIR/reader-tests"
