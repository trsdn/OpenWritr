#!/bin/bash
# Fail when an OpenWritr executable was built without the FoundationModels SDK.
#
# Apple Intelligence is guarded by `#if canImport(FoundationModels)`. With an SDK older than
# macOS 26 the build still succeeds but the provider is compiled out, so it can never be
# selected. v1.7.0 and v1.7.1 shipped that way.
set -euo pipefail

EXECUTABLE="${1:?Usage: $0 path/to/OpenWritr}"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "Executable not found: $EXECUTABLE" >&2
    exit 2
fi

if ! otool -L "$EXECUTABLE" | grep -q 'FoundationModels\.framework'; then
    echo "$EXECUTABLE does not link FoundationModels: Apple Intelligence was compiled out." >&2
    echo "Build with Xcode 26 or later (macOS 26 SDK)." >&2
    exit 1
fi

echo "FoundationModels is linked: Apple Intelligence is compiled in."
