// Copyright 2026 Cisco Systems, Inc. and its affiliates
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
)

func TestGeminiCLILifecycleBindsOfficialConfigDirectory(t *testing.T) {
	root := t.TempDir()
	dataRoot := filepath.Join(root, ".defenseclaw")
	geminiConfigDir := filepath.Join(root, ".gemini")
	transaction := setupTransaction{
		DataRoot:                dataRoot,
		GeminiConfigDir:         geminiConfigDir,
		PreviousGeminiConfigDir: geminiConfigDir,
	}

	env := transactionChildEnv(transaction)
	if got := envValue(env, "DEFENSECLAW_GEMINI_CONFIG_DIR"); !samePath(got, geminiConfigDir) {
		t.Fatalf("Gemini maintenance binding = %q, want %q", got, geminiConfigDir)
	}
	args, err := connectorLifecycleCommandArgs(dataRoot, "geminicli", "teardown", env)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"connector", "teardown",
		"--connector", "geminicli",
		"--data-dir", dataRoot,
		"--config-home", geminiConfigDir,
		"--json",
	}
	if !reflect.DeepEqual(args, want) {
		t.Fatalf("Gemini lifecycle args = %q, want %q", args, want)
	}
}

func TestGeminiCLIReconciliationUsesExactCustodyHome(t *testing.T) {
	root := t.TempDir()
	geminiConfigDir := filepath.Join(root, ".gemini")
	transaction := setupTransaction{
		ID:                      strings.Repeat("a", 32),
		DataRoot:                filepath.Join(root, ".defenseclaw"),
		PreviousConnectors:      []string{"geminicli"},
		PreviousGeminiConfigDir: geminiConfigDir,
		GeminiConfigDir:         geminiConfigDir,
	}

	var calls []string
	recorder := reconcileRemovedConnectors(
		transaction,
		filepath.Join(root, "defenseclaw-gateway.exe"),
		transactionPreviousChildEnv(transaction),
		func(_, _, connectorName, action string, env []string) error {
			if connectorName != "geminicli" {
				t.Fatalf("connector = %q, want geminicli", connectorName)
			}
			calls = append(
				calls,
				action+":"+envValue(env, "DEFENSECLAW_GEMINI_CONFIG_DIR"),
			)
			return nil
		},
	)
	want := []string{
		"teardown:" + geminiConfigDir,
		"verify:" + geminiConfigDir,
	}
	if !reflect.DeepEqual(calls, want) {
		t.Fatalf("Gemini reconciliation calls = %v, want %v", calls, want)
	}
	if len(recorder.failures) != 0 {
		t.Fatalf("Gemini reconciliation retained failures: %+v", recorder.failures)
	}
}

func TestGeminiCLIManagedBackupBindsCleanupToExactHome(t *testing.T) {
	root := t.TempDir()
	dataRoot := filepath.Join(root, ".defenseclaw")
	geminiConfigDir := filepath.Join(root, ".gemini")
	backupPath := filepath.Join(dataRoot, "connector_backups", "geminicli", "config.json")
	if err := writeFileDurable(backupPath, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	transaction := setupTransaction{
		DataRoot:                dataRoot,
		PreviousGeminiConfigDir: geminiConfigDir,
		GeminiConfigDir:         geminiConfigDir,
		PreviousState: &installState{
			GeminiConfigDir: geminiConfigDir,
		},
	}
	if !connectorManagedBackupExists(dataRoot, "geminicli") {
		t.Fatal("Gemini managed backup was not recognized as cleanup authority")
	}
	if got := connectorCleanupHomes(transaction, "geminicli"); !reflect.DeepEqual(
		got,
		[]string{geminiConfigDir},
	) {
		t.Fatalf("Gemini cleanup homes = %v, want only %s", got, geminiConfigDir)
	}
}

func TestGeminiCLICustodyDiscoveryExcludesAntigravityState(t *testing.T) {
	root := t.TempDir()
	dataRoot := filepath.Join(root, ".defenseclaw")
	geminiMarker := filepath.Join(dataRoot, "connector_backups", "geminicli", "config.json")
	antigravityMarker := filepath.Join(dataRoot, "connector_backups", "antigravity", "config.json")
	for path, body := range map[string][]byte{
		geminiMarker:      []byte("{}\n"),
		antigravityMarker: []byte("{\"owner\":\"antigravity\"}\n"),
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	got, err := connectorsForNativeUninstall(&installState{Connector: "none"}, dataRoot)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []string{"geminicli"}) {
		t.Fatalf("custody roster = %v, want only geminicli", got)
	}
	if body, err := os.ReadFile(antigravityMarker); err != nil {
		t.Fatal(err)
	} else if string(body) != "{\"owner\":\"antigravity\"}\n" {
		t.Fatalf("Antigravity custody marker changed during discovery: %q", body)
	}
}

func TestGeminiCLIBackupBindingRejectsAntigravityTarget(t *testing.T) {
	root := t.TempDir()
	dataRoot := filepath.Join(root, ".defenseclaw")
	backupPath := filepath.Join(dataRoot, "connector_backups", "geminicli", "config.json")
	antigravityPath := filepath.Join(root, ".gemini", "config", "hooks.json")
	body := []byte(`{"path":` + strconv.Quote(antigravityPath) + `}` + "\n")
	if err := writeFileDurable(backupPath, body, 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := inferManagedConnectorHome(
		dataRoot,
		"geminicli",
		"config",
		filepath.Join(root, ".gemini"),
	)
	if err == nil || !strings.Contains(err.Error(), "owned Gemini CLI settings.json") {
		t.Fatalf("Antigravity target entered Gemini backup custody: %v", err)
	}
}

func TestGeminiCLIInstallStateHomeValidation(t *testing.T) {
	installRoot, dataRoot, maintenancePath := testTransactionRoots(t)
	state := testInstallState(
		installRoot,
		dataRoot,
		maintenancePath,
		testCurrentTransactionID,
		"1.2.3",
	)
	state.Connector = "geminicli"
	state.GeminiConfigDir = filepath.Join(filepath.Dir(dataRoot), ".gemini")
	if err := validateInstallStateForRoots(
		&state,
		installRoot,
		dataRoot,
		maintenancePath,
	); err != nil {
		t.Fatalf("valid Gemini installer state rejected: %v", err)
	}

	state.GeminiConfigDir = "relative"
	if err := validateInstallStateForRoots(
		&state,
		installRoot,
		dataRoot,
		maintenancePath,
	); err == nil {
		t.Fatal("relative Gemini configuration directory was accepted")
	}
}
