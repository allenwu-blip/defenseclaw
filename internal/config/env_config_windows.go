// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package config

import (
	"os"

	"github.com/defenseclaw/defenseclaw/internal/managed"
	"golang.org/x/sys/windows"
)

// DefaultEnvConfigPath is the AVC drop location on Windows managed
// installs. Mirrors the macOS `/opt/cisco/secureclient/defenseclaw/...`
// convention — the file is authored by Cisco Secure Client's AVC
// packaging pipeline under the Secure Client per-machine data root,
// separate from DefenseClaw's own %ProgramData%\Cisco\DefenseClaw\
// tree. Keeping AVC-owned artifacts under the AVC-owned tree keeps
// ACL ownership unambiguous: AVC gets Write, the gateway service
// account gets Read.
const DefaultEnvConfigPath = `C:\ProgramData\Cisco\Cisco Secure Client\DefenseClaw\env_config.json`

// openEnvConfig on Windows validates path-level trust up front (owner,
// no world/non-admin write, no reparse point, ancestor chain
// administrator-owned) via managed.ValidateTrustedFilePath, then does a
// plain read-only open.
//
// Windows has no direct O_NOFOLLOW-equivalent flag on os.OpenFile, so
// the darwin/linux "single-syscall atomic open + O_NOFOLLOW" pattern is
// not available. Instead we rely on the fact that only administrators
// can write into the AVC-owned parent directory (validated by
// ValidateTrustedFilePath's ancestor walk) — an attacker without admin
// cannot swap the file between validation and open, and an attacker
// WITH admin is inside the trust boundary of this check to begin with.
//
// The trust check is skipped when the process is not running as an
// administrator (dev boxes, unit tests, opensource local runs) — same
// escape valve the Unix trustEnvConfigFilePlatform applies when
// os.Geteuid() != 0. DEFENSECLAW_ENV_CONFIG_SKIP_TRUST=1 also disables
// the check for tests that need to exercise the parse path without
// touching an admin-owned directory.
//
// A missing file surfaces as os.ErrNotExist so LoadEnvConfigEndpoint
// can convert it to ErrEnvConfigMissing (the pre-arrival case). Trust
// failures surface as the wrapped ValidateTrustedFilePath error, which
// LoadEnvConfigEndpoint's caller (ConfigManager.Reload) treats the same
// as a malformed overlay: log + retain the previously-active endpoint.
func openEnvConfig(path string) (*os.File, error) {
	// Probe existence first so a missing file yields os.ErrNotExist
	// (mapped to ErrEnvConfigMissing upstream) rather than a wrapped
	// trust-validation error that would be logged as "malformed
	// overlay" in the ConfigManager reload path.
	if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	if shouldEnforceEnvConfigTrust() {
		if err := managed.ValidateTrustedFilePath(path, "env_config"); err != nil {
			return nil, err
		}
	}
	return os.Open(path)
}

// trustEnvConfigFilePlatform is a no-op on Windows because the full
// trust check (ancestor chain admin-owned, no reparse point, no world-
// writable ACLs) already ran inside openEnvConfig via
// managed.ValidateTrustedFilePath. Splitting the check across
// openEnvConfig and this hook would double-validate for no gain and
// diverge from the Unix path structure (see env_config_unix.go).
func trustEnvConfigFilePlatform(_ os.FileInfo) error {
	return nil
}

// shouldEnforceEnvConfigTrust reports whether the caller is running in a
// posture that can actually satisfy the managed-install trust invariants
// (running as SYSTEM or a member of Administrators, with the file under
// an admin-owned tree). When the caller is a normal user (dev boxes,
// unit tests, opensource local runs) the invariants cannot hold, so we
// return false and let LoadEnvConfigEndpoint parse the file for
// correctness only. Matches the Unix os.Geteuid() != 0 escape.
//
// DEFENSECLAW_ENV_CONFIG_SKIP_TRUST=1 is honored regardless of
// elevation — tests set it to exercise the parse path deterministically
// without depending on how the process was launched.
func shouldEnforceEnvConfigTrust() bool {
	if os.Getenv("DEFENSECLAW_ENV_CONFIG_SKIP_TRUST") == "1" {
		return false
	}
	return currentProcessIsElevated()
}

// currentProcessIsElevated returns true when the process token reports
// TokenElevation.TokenIsElevated. This is the same check `whoami /priv`
// and MSDN's "Determining whether the User is a Member of Administrators"
// example use. A failure to query the token is treated as "not
// elevated" so a broken environment fails toward the permissive path
// (parse-only), which is safer for tests than a hard error.
func currentProcessIsElevated() bool {
	var token windows.Token
	if err := windows.OpenProcessToken(
		windows.CurrentProcess(),
		windows.TOKEN_QUERY,
		&token,
	); err != nil {
		return false
	}
	defer token.Close()
	return token.IsElevated()
}
