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
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"

bash -n "$REPO_ROOT/scripts/build-macos-app-release.sh"

python3 - "$ROOT" "$REPO_ROOT" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
build = (repo_root / "scripts/build-macos-app-release.sh").read_text(encoding="utf-8")
runtime = (root / "DefenseClawMac/DataLayer/RuntimeInstaller.swift").read_text(encoding="utf-8")
first_run = (root / "DefenseClawMac/Features/FirstRunView.swift").read_text(encoding="utf-8")
updater = (root / "DefenseClawMac/DataLayer/UpdateChecker.swift").read_text(encoding="utf-8")

checks = {
    "release uses the reviewed runtime candidate manifest": 'upgrade-manifest.json' in build,
    "release uses the reviewed runtime candidate checksums": 'runtime-candidate-checksums.txt' in build,
    "sealed gateway input is copied byte-for-byte": 'cmp -s "${GATEWAY_INPUT}" "${GATEWAY}"' in build,
    "dependency lock includes artifact hashes": '--generate-hashes' in build,
    "dependency lock authenticates approved direct references": 'validate_dependency_lock.py' in build,
    "dependency lock no longer uses a blanket URL ban": "untrusted direct URL or local path" not in build,
    "dependency lock excludes the separately authenticated root wheel": '--no-emit-package defenseclaw' in build,
    "dependency lock is embedded": 'runtime-requirements.lock' in build,
    "lock resolution ignores ambient uv configuration": 'uv --no-config pip compile' in build,
    "runtime requires dependency hashes": '"--require-hashes"' in runtime,
    "runtime ignores ambient uv configuration": '"--no-config", "pip", "install"' in runtime,
    "runtime installs only from the signed dependency lock": '"--requirements", materializedDependencyLock' in runtime,
    "runtime installs authenticated root wheel without re-resolving dependencies": '"--no-deps", materializedWheel' in runtime,
    "runtime does not apply unlocked overrides": 'wheelArguments += ["--overrides"' not in runtime,
    "first-run no longer references mutable main": 'defenseclaw/main/scripts' not in first_run,
    "updater pins Cisco bundle identity": 'expectedBundleIdentifier = "com.cisco.defenseclaw.macos"' in updater,
    "updater binds the running Developer ID team": 'kSecCodeInfoTeamIdentifier' in updater,
    "updater disables ad-hoc self-update": 'this app is not signed by a trusted Apple Developer ID team' in updater,
    "updater enforces the derived designated requirement": '"-R=\\(expectedCodeRequirement)"' in updater,
    "installer authenticates the signed checksum manifest": '$cosign\\" verify-blob' in updater,
    "installer pins the release workflow identity": 'release.yaml@refs/heads/main' in updater,
}

failed = [label for label, ok in checks.items() if not ok]
if failed:
    for label in failed:
        print(f"FAILED: {label}", file=sys.stderr)
    raise SystemExit(1)
print("Supply-chain safety tests passed")
PYEOF
