#!/bin/sh
# Runs the zmx exposé adapter checks headlessly.
#
# The in-app harness (ZmxExposeAdapterPreview.swift) follows the repo's
# convention of a SwiftUI canvas preview, which needs Xcode open. This compiles
# the same production sources against small stubs and runs the checks from the
# terminal, so the result is reproducible in CI or over ssh.
#
# It compiles the REAL files -- no copies to drift -- plus Stubs.swift for the
# types the pure logic touches that this harness does not link (MultiplexerType,
# SSHConfig, and DisplayWidth -- the real one pulls in GhosttyKit). DEBUG is
# undefined here, so the `#if DEBUG` SwiftUI sections of the sources compile out.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -o "$out/runner" \
    -module-cache-path "$out/module-cache" \
    "$root/rootshell/Features/Multiplexer/Expose/MultiplexerExposeAdapter.swift" \
    "$root/rootshell/Features/Multiplexer/Expose/MultiplexerExposeModel.swift" \
    "$root/rootshell/Features/Multiplexer/Expose/ZmxExposeAdapter.swift" \
    "$root/rootshell/Features/SSH/Discovery/ZmxDiscoveryParser.swift" \
    "$root/rootshell/Core/Terminal/WorkingDirectoryURI.swift" \
    "$root/docs/zmx-expose-checks/Stubs.swift" \
    "$root/docs/zmx-expose-checks/main.swift"
"$out/runner"
