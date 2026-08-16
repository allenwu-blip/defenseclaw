// Copyright 2026 Cisco Systems, Inc. and its affiliates
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func enterpriseSetupRepositoryRoot(t *testing.T) string {
	t.Helper()
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve enterprise Setup test source")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(source), "..", ".."))
}

func readEnterpriseSetupContractFile(t *testing.T, relative string) string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(enterpriseSetupRepositoryRoot(t), filepath.FromSlash(relative)))
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func TestEnterpriseBuilderProducesOnlyTheMachineWideBootstrap(t *testing.T) {
	builder := readEnterpriseSetupContractFile(t, "scripts/build-windows-enterprise-installer.ps1")
	for _, required := range []string{
		"DefenseClawSetup-Enterprise-x64.exe",
		"./cmd/defenseclaw-enterprise-setup",
		"'managed-enterprise'",
		"'enterprise-setup'",
		"defenseclaw-gateway.exe",
		"defenseclaw-hook.exe",
		"install-enterprise.ps1",
		"DefenseClawEnterprise.psm1",
	} {
		if !strings.Contains(builder, required) {
			t.Errorf("enterprise builder is missing %q", required)
		}
	}
	if strings.Contains(builder, "-DistributionFlavor managed-enterprise") {
		t.Fatal("enterprise builder still relabels the ordinary per-user Setup")
	}
}

func TestOrdinarySetupBuilderCannotBeRelabeledAsEnterprise(t *testing.T) {
	builder := readEnterpriseSetupContractFile(t, "scripts/build-windows-installer.ps1")
	if !strings.Contains(builder, "[ValidateSet('oss')]") {
		t.Fatal("ordinary Setup builder is not restricted to the oss distribution flavor")
	}
	if strings.Contains(builder, "[ValidateSet('oss', 'managed-enterprise')]") {
		t.Fatal("ordinary Setup builder still accepts the managed-enterprise label")
	}
}

func TestEnterpriseWorkflowPublishesTheExactUnsignedCertificationArtifact(t *testing.T) {
	workflow := readEnterpriseSetupContractFile(t, ".github/workflows/windows-enterprise-setup.yml")
	for _, required := range []string{
		"scripts/build-windows-enterprise-installer.ps1",
		"DefenseClawSetup-Enterprise-x64.exe",
		"-SkipSigning",
		"AI_COMMON_READ_TOKEN",
		"environment: windows-enterprise-build",
		"pull_request:",
		"github.event.pull_request.head.sha || github.sha",
		"needs.managed-gateway.outputs.source_commit",
		"GIT_CONFIG_COUNT: 1",
		"GIT_TERMINAL_PROMPT: 0",
	} {
		if !strings.Contains(workflow, required) {
			t.Errorf("enterprise workflow is missing %q", required)
		}
	}
}
