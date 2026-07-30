// Copyright 2026 Cisco Systems, Inc. and its affiliates
// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/defenseclaw/defenseclaw/internal/gateway/connector"
	"github.com/defenseclaw/defenseclaw/internal/testenv"
)

const ownedCodexOTLPFixture = `[otel.exporter.otlp-http]
endpoint = "http://127.0.0.1:18970/v1/logs"

[otel.exporter.otlp-http.headers]
x-defenseclaw-source = "codex"
x-defenseclaw-client = "codex-otel/1.0"
`

func TestBindConnectorLifecycleConfigHomeOverridesAmbientAndRestoresIt(t *testing.T) {
	root := t.TempDir()
	ambient := filepath.Join(root, "ambient")
	bound := filepath.Join(root, "bound")
	t.Setenv("CODEX_HOME", ambient)
	connectorFlagConfigHome = bound
	t.Cleanup(func() { connectorFlagConfigHome = "" })

	restore, err := bindConnectorLifecycleConfigHome("codex")
	if err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("CODEX_HOME"); got != bound {
		t.Fatalf("bound CODEX_HOME = %q, want %q", got, bound)
	}
	restore()
	if got := os.Getenv("CODEX_HOME"); got != ambient {
		t.Fatalf("restored CODEX_HOME = %q, want %q", got, ambient)
	}
}

func TestBindConnectorLifecycleConfigHomeTargetsGeminiSettingsAndRestoresIt(t *testing.T) {
	root := t.TempDir()
	configDir := filepath.Join(root, ".gemini")
	previous := filepath.Join(root, "previous", "settings.json")
	connector.GeminiSettingsPathOverride = previous
	connectorFlagConfigHome = configDir
	t.Cleanup(func() {
		connectorFlagConfigHome = ""
		connector.GeminiSettingsPathOverride = ""
	})

	restore, err := bindConnectorLifecycleConfigHome("geminicli")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := connector.GeminiSettingsPathOverride, filepath.Join(configDir, "settings.json"); got != want {
		t.Fatalf("bound Gemini settings path = %q, want %q", got, want)
	}
	restore()
	if got := connector.GeminiSettingsPathOverride; got != previous {
		t.Fatalf("restored Gemini settings path = %q, want %q", got, previous)
	}
}

func TestBindConnectorLifecycleConfigHomeRejectsUnsafeTargets(t *testing.T) {
	root := t.TempDir()
	unnormalized := root + string(filepath.Separator) + "child" + string(filepath.Separator) + ".." + string(filepath.Separator) + "codex"
	for _, test := range []struct {
		name      string
		home      string
		connector string
		want      string
	}{
		{name: "relative", home: "relative", connector: "codex", want: "absolute normalized path"},
		{name: "unnormalized", home: unnormalized, connector: "codex", want: "absolute normalized path"},
		{name: "newline", home: root + "\nother", connector: "codex", want: "absolute normalized path"},
		{name: "unsupported", home: filepath.Join(root, "home"), connector: "openclaw", want: "unsupported for connector"},
	} {
		t.Run(test.name, func(t *testing.T) {
			connectorFlagConfigHome = test.home
			t.Cleanup(func() { connectorFlagConfigHome = "" })
			_, err := bindConnectorLifecycleConfigHome(test.connector)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestConnectorVerifyUsesExplicitConfigHomeWithoutMutation(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "data")
	ambient := filepath.Join(root, "ambient")
	bound := filepath.Join(root, "bound")
	if err := os.MkdirAll(bound, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(bound, "config.toml")
	wantConfig := []byte(ownedCodexOTLPFixture)
	if err := os.WriteFile(configPath, wantConfig, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CODEX_HOME", ambient)
	defer withConnectorState(t, dataDir, "codex")()

	stdout, stderr, exitCode := runConnectorCmd(
		t,
		"verify",
		"--connector", "codex",
		"--data-dir", dataDir,
		"--config-home", bound,
		"--json",
	)
	if exitCode != 1 || stderr != "" || !strings.Contains(stdout, "config.toml [otel]") {
		t.Fatalf("explicit-home verify: exit=%d stdout=%q stderr=%q", exitCode, stdout, stderr)
	}
	gotConfig, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotConfig, wantConfig) {
		t.Fatal("explicit-home verification mutated the live configuration fixture")
	}
	if got := os.Getenv("CODEX_HOME"); got != ambient {
		t.Fatalf("CODEX_HOME after verify = %q, want restored ambient %q", got, ambient)
	}
}

func TestCursorVerifyUsesExplicitConfigHomeWithoutVendorEnvironmentOverride(t *testing.T) {
	root := t.TempDir()
	dataDir := testenv.PrivateTempDir(t)
	bound := filepath.Join(root, "cursor")
	if err := os.MkdirAll(bound, 0o700); err != nil {
		t.Fatal(err)
	}
	adapter := filepath.Join(dataDir, "hooks", "cursor-hook.ps1")
	config := []byte(`{"version":1,"hooks":{"preToolUse":[{"type":"command","command":"` +
		`& '` + strings.ReplaceAll(adapter, `\`, `\\`) + `'` +
		`","timeout":30,"failClosed":false}]}}`)
	configPath := filepath.Join(bound, "hooks.json")
	if err := os.WriteFile(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	defer withConnectorState(t, dataDir, "cursor")()

	stdout, stderr, exitCode := runConnectorCmd(
		t,
		"verify",
		"--connector", "cursor",
		"--data-dir", dataDir,
		"--config-home", bound,
		"--json",
	)
	if exitCode != 1 || stderr != "" ||
		!strings.Contains(stdout, `"clean":false`) ||
		!strings.Contains(stdout, "cursor-hook") {
		t.Fatalf("Cursor explicit-home verify: exit=%d stdout=%q stderr=%q", exitCode, stdout, stderr)
	}
	gotConfig, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotConfig, config) {
		t.Fatal("Cursor explicit-home verification mutated hooks.json")
	}
	if _, exists := os.LookupEnv("CURSOR_HOME"); exists {
		t.Fatal("Cursor maintenance invented a vendor CURSOR_HOME environment override")
	}
}

func TestCursorReconcileWritesOnlyExplicitConfigHome(t *testing.T) {
	root := t.TempDir()
	dataDir := testenv.PrivateTempDir(t)
	bound := filepath.Join(root, "cursor")
	for _, path := range []string{bound} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := validateConnectorLifecycleConfigHomePath(dataDir); err != nil {
		t.Fatal(err)
	}
	defer withConnectorState(t, dataDir, "cursor")()
	if _, err := connector.EnsureHookAPIToken(dataDir, "cursor"); err != nil {
		t.Fatal(err)
	}

	stdout, stderr, _ := runConnectorCmd(
		t,
		"reconcile",
		"--connector", "cursor",
		"--data-dir", dataDir,
		"--config-home", bound,
		"--json",
	)
	if !strings.Contains(stdout, `"connector":"cursor"`) ||
		(stderr != "" && !strings.Contains(stderr, "preview on windows")) {
		t.Fatalf("Cursor reconcile: stdout=%q stderr=%q", stdout, stderr)
	}
	hooksPath := filepath.Join(bound, "hooks.json")
	hooks, err := os.ReadFile(hooksPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(hooks, []byte(`"failClosed": false`)) ||
		!bytes.Contains(hooks, []byte(`"preToolUse"`)) {
		t.Fatalf("Cursor reconcile wrote an incomplete registration: %s", hooks)
	}
}

func TestConnectorConfigHomeFlagIsMaintenanceOnly(t *testing.T) {
	flag := connectorCmd.PersistentFlags().Lookup("config-home")
	if flag == nil || !flag.Hidden {
		t.Fatal("config-home flag must remain hidden from the operator surface")
	}
}

func TestBindConnectorLifecycleConfigHomeRejectsSymlinkChain(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("synthetic symlink fixture unavailable: %v", err)
	}
	connectorFlagConfigHome = filepath.Join(link, "child")
	t.Cleanup(func() { connectorFlagConfigHome = "" })
	_, err := bindConnectorLifecycleConfigHome("codex")
	if err == nil || !strings.Contains(err.Error(), "unsafe") {
		t.Fatalf("error = %v, want unsafe path refusal", err)
	}
}
