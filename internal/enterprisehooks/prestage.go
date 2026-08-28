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

package enterprisehooks

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/defenseclaw/defenseclaw/internal/gateway/connector"
)

// PreStage materializes a connector's per-user hook artifacts without
// modifying the connector's native configuration. It is used when the
// installer knows the connector is configured for enterprise protection but
// cannot yet resolve a supported agent version. A later manifest reconcile
// performs the normal activation once version discovery succeeds.
//
// PreStage deliberately does not create a hook contract lock, native config
// backup, or native hook entry. The presence of files under ~/.defenseclaw is
// therefore not treated as evidence that the agent is actively protected.
func PreStage(ctx context.Context, opts InstallOptions) (InstallResult, error) {
	if ctx == nil {
		return InstallResult{}, fmt.Errorf("enterprise hooks: pre-stage context is nil")
	}
	home, err := validateUserHome(opts.UserHome)
	if err != nil {
		return InstallResult{}, err
	}
	uid, gid, err := resolveOwner(home, opts.OwnerUID, opts.OwnerGID)
	if err != nil {
		return InstallResult{}, err
	}
	if err := validateHomeOwner(home, uid); err != nil {
		return InstallResult{}, err
	}

	dataDir := strings.TrimSpace(opts.DataDir)
	if dataDir == "" {
		dataDir = filepath.Join(home, ".defenseclaw")
	}
	dataDir, err = filepath.Abs(dataDir)
	if err != nil {
		return InstallResult{}, fmt.Errorf("enterprise hooks: resolve pre-stage data dir: %w", err)
	}
	if err := validateUserDataDir(home, dataDir, uid); err != nil {
		return InstallResult{}, err
	}

	reg := opts.Registry
	if reg == nil {
		reg = connector.NewDefaultRegistry()
	}
	name := strings.ToLower(strings.TrimSpace(opts.ConnectorName))
	if name == "" {
		return InstallResult{}, fmt.Errorf("enterprise hooks: connector is required")
	}
	conn, ok := reg.Get(name)
	if !ok {
		return InstallResult{}, fmt.Errorf("enterprise hooks: unknown connector %q", name)
	}
	if connector.IsProxyConnector(conn.Name()) {
		return InstallResult{}, fmt.Errorf("enterprise hooks: connector %q is proxy/plugin setup-only; pre-stage is not supported", conn.Name())
	}
	if !connector.OwnsManagedHookRuntime(conn) {
		return InstallResult{}, fmt.Errorf("enterprise hooks: connector %q does not own a managed hook runtime", conn.Name())
	}
	if !connector.ConnectorSupportedOnHostOS(conn.Name()) {
		return InstallResult{}, fmt.Errorf("enterprise hooks: connector %q is not supported on this host OS", conn.Name())
	}

	setupOpts := connector.SetupOpts{
		DataDir:           dataDir,
		ProxyAddr:         strings.TrimSpace(opts.ProxyAddr),
		APIAddr:           strings.TrimSpace(opts.APIAddr),
		APIToken:          strings.TrimSpace(opts.APIToken),
		Interactive:       false,
		ManagedEnterprise: true,
		HookFailMode:      strings.TrimSpace(opts.HookFailMode),
		HILTEnabled:       opts.HILTEnabled,
		WorkspaceDir:      strings.TrimSpace(opts.WorkspaceDir),
	}

	hookDir := filepath.Join(dataDir, "hooks")
	err = connector.WithUserHomeDir(home, func() error {
		return withOwnerCredentials(uid, gid, func() error {
			if err := connector.WriteHookScriptsForConnectorObjectWithOpts(hookDir, setupOpts, conn); err != nil {
				return fmt.Errorf("enterprise hooks: pre-stage connector %s hook artifacts: %w", conn.Name(), err)
			}
			return nil
		})
	})
	if err != nil {
		return InstallResult{}, err
	}

	return InstallResult{
		Connector: name,
		UserHome:  home,
		DataDir:   dataDir,
	}, nil
}
