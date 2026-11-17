#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests build/module-cache
swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/PortListener.swift Sources/TunnelFailure.swift Sources/Tunnel.swift Sources/TunnelStore.swift Tests/main.swift -o build/tests/test
build/tests/test "$PWD/Tests/fake-ssh"

swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/SingleInstance.swift Tests/SingleInstance/main.swift -o build/tests/single-instance
build/tests/single-instance
