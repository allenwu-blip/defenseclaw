#!/bin/bash
# Copyright 2026 Cisco Systems, Inc. and its affiliates
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/defenseclaw-runtime-artifact-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
MODULE_CACHE="$BUILD_DIR/ModuleCache"
mkdir -p "$MODULE_CACHE"
BOUNDARY='// TEST-EXTRACT-BOUNDARY: RuntimePayloadTestSupport'

extract_runtime_payload() {
  local source="$1"
  local destination="$2"
  local marker_count
  marker_count="$(grep -Fxc -- "$BOUNDARY" "$source" || true)"
  [[ "$marker_count" == 1 ]] || {
    echo "RuntimeInstaller.swift must contain exactly one RuntimePayload extraction boundary" >&2
    return 1
  }
  awk -v boundary="$BOUNDARY" '$0 == boundary { exit } { print }' \
    "$source" > "$destination"
}

# RuntimePayload is intentionally kept in RuntimeInstaller.swift beside its
# only consumer. Compile that production type without the AppState extension.
RUNTIME_INSTALLER="$ROOT/DefenseClawMac/DataLayer/RuntimeInstaller.swift"
extract_runtime_payload "$RUNTIME_INSTALLER" "$BUILD_DIR/RuntimePayload.swift"

printf '%s\n' '// no extraction boundary' > "$BUILD_DIR/missing-boundary.swift"
if extract_runtime_payload "$BUILD_DIR/missing-boundary.swift" "$BUILD_DIR/ignored.swift" 2>/dev/null; then
  echo "missing RuntimePayload extraction boundary was accepted" >&2
  exit 1
fi
cp "$RUNTIME_INSTALLER" "$BUILD_DIR/duplicate-boundary.swift"
printf '%s\n' "$BOUNDARY" >> "$BUILD_DIR/duplicate-boundary.swift"
if extract_runtime_payload "$BUILD_DIR/duplicate-boundary.swift" "$BUILD_DIR/ignored.swift" 2>/dev/null; then
  echo "duplicate RuntimePayload extraction boundaries were accepted" >&2
  exit 1
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" xcrun swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$BUILD_DIR/RuntimePayload.swift" \
  "$ROOT/Tests/RuntimeProtectedArtifactTests.swift" \
  -o "$BUILD_DIR/RuntimeProtectedArtifactTests"

"$BUILD_DIR/RuntimeProtectedArtifactTests"
