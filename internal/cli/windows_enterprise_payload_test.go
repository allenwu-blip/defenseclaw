// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/cobra"

	windowspayload "github.com/defenseclaw/defenseclaw/packaging/windows"
)

func TestWindowsEnterprisePayloadCarriesBothLifecycleScripts(t *testing.T) {
	if !windowspayload.Available() {
		t.Fatal("Windows builds must carry the lifecycle scripts")
	}
	for name, staged := range map[string][]byte{
		windowspayload.InstallerName: windowspayload.Installer(),
		windowspayload.ModuleName:    windowspayload.Module(),
	} {
		source, err := os.ReadFile(filepath.Join("..", "..", "packaging", "windows", name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if !bytes.Equal(source, staged) {
			t.Fatalf("embedded %s does not match its source file", name)
		}
	}
}

func TestStageWindowsEnterprisePayloadWritesThePairAndCleansUp(t *testing.T) {
	originalValidator := windowsEnterpriseTrustValidator
	t.Cleanup(func() { windowsEnterpriseTrustValidator = originalValidator })

	directory := t.TempDir()
	validated := ""
	windowsEnterpriseTrustValidator = func(script string) error {
		validated = script
		return nil
	}

	script, cleanup, err := stageWindowsEnterprisePayloadIn(func() (string, error) {
		return directory, nil
	})
	if err != nil {
		t.Fatalf("stage embedded installer: %v", err)
	}
	if want := filepath.Join(directory, windowspayload.InstallerName); script != want {
		t.Fatalf("staged script = %q, want %q", script, want)
	}
	if validated != script {
		t.Fatalf("trust validation ran on %q, want the staged script %q", validated, script)
	}
	// The script imports its module by name from its own directory, so both
	// files have to be present before PowerShell starts.
	for name, want := range map[string][]byte{
		windowspayload.InstallerName: windowspayload.Installer(),
		windowspayload.ModuleName:    windowspayload.Module(),
	} {
		got, readErr := os.ReadFile(filepath.Join(directory, name))
		if readErr != nil {
			t.Fatalf("read staged %s: %v", name, readErr)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("staged %s does not match the embedded copy", name)
		}
	}
	if err := cleanup(); err != nil {
		t.Fatalf("cleanup staged installer: %v", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("staging directory survived cleanup: %v", err)
	}
}

func TestStageWindowsEnterprisePayloadRemovesStagingWhenTrustFails(t *testing.T) {
	originalValidator := windowsEnterpriseTrustValidator
	t.Cleanup(func() { windowsEnterpriseTrustValidator = originalValidator })

	directory := filepath.Join(t.TempDir(), "staging")
	windowsEnterpriseTrustValidator = func(string) error {
		return errors.New("untrusted staging root")
	}

	_, _, err := stageWindowsEnterprisePayloadIn(func() (string, error) {
		if mkErr := os.Mkdir(directory, 0o700); mkErr != nil {
			return "", mkErr
		}
		return directory, nil
	})
	if err == nil {
		t.Fatal("staging into an untrusted root must fail closed")
	}
	if _, statErr := os.Stat(directory); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("rejected staging survived: %v", statErr)
	}
}

func TestRunWindowsEnterpriseLifecycleStagesTheEmbeddedInstallerWhenDiscoveryFindsNone(
	t *testing.T,
) {
	originalRunner := windowsEnterpriseCommandRunner
	originalScriptFinder := windowsEnterpriseScriptFinder
	originalStager := windowsEnterprisePayloadStager
	t.Cleanup(func() {
		windowsEnterpriseCommandRunner = originalRunner
		windowsEnterpriseScriptFinder = originalScriptFinder
		windowsEnterprisePayloadStager = originalStager
	})
	t.Setenv(windowsEnterpriseInstallerEnv, "")

	staged := filepath.Join(t.TempDir(), windowspayload.InstallerName)
	cleaned := false
	windowsEnterpriseScriptFinder = func(string) (string, error) {
		return "", fmt.Errorf("%w; pass --installer", errWindowsEnterpriseInstallerNotFound)
	}
	windowsEnterprisePayloadStager = func() (string, func() error, error) {
		return staged, func() error {
			cleaned = true
			return nil
		}, nil
	}
	ran := ""
	windowsEnterpriseCommandRunner = func(
		_ context.Context,
		_ *cobra.Command,
		script string,
		_ []string,
	) error {
		ran = script
		return nil
	}

	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	if err := runWindowsEnterpriseLifecycle(
		context.Background(),
		cmd,
		"status",
		&windowsEnterpriseLifecycleOptions{},
	); err != nil {
		t.Fatalf("status with no installer on disk: %v", err)
	}
	if ran != staged {
		t.Fatalf("ran %q, want the staged embedded installer %q", ran, staged)
	}
	if !cleaned {
		t.Fatal("staged installer was left behind")
	}
}

func TestRunWindowsEnterpriseLifecycleFailsRatherThanStageOverAnExplicitInstaller(t *testing.T) {
	originalRunner := windowsEnterpriseCommandRunner
	originalScriptFinder := windowsEnterpriseScriptFinder
	originalStager := windowsEnterprisePayloadStager
	t.Cleanup(func() {
		windowsEnterpriseCommandRunner = originalRunner
		windowsEnterpriseScriptFinder = originalScriptFinder
		windowsEnterprisePayloadStager = originalStager
	})

	windowsEnterpriseScriptFinder = func(string) (string, error) {
		return "", fmt.Errorf("%w; pass --installer", errWindowsEnterpriseInstallerNotFound)
	}
	windowsEnterprisePayloadStager = func() (string, func() error, error) {
		t.Fatal("an explicitly named installer must never fall back to the embedded copy")
		return "", nil, nil
	}
	windowsEnterpriseCommandRunner = func(
		context.Context,
		*cobra.Command,
		string,
		[]string,
	) error {
		t.Fatal("a missing explicit installer must not reach PowerShell")
		return nil
	}

	for name, opts := range map[string]*windowsEnterpriseLifecycleOptions{
		"flag": {installerPath: filepath.Join(t.TempDir(), "missing.ps1")},
		"env":  {},
	} {
		t.Run(name, func(t *testing.T) {
			if name == "env" {
				t.Setenv(
					windowsEnterpriseInstallerEnv,
					filepath.Join(t.TempDir(), "missing.ps1"),
				)
			} else {
				t.Setenv(windowsEnterpriseInstallerEnv, "")
			}
			cmd := &cobra.Command{}
			cmd.SetOut(&bytes.Buffer{})
			cmd.SetErr(&bytes.Buffer{})
			if err := runWindowsEnterpriseLifecycle(
				context.Background(),
				cmd,
				"status",
				opts,
			); err == nil {
				t.Fatal("a named installer that is missing must fail")
			}
		})
	}
}
