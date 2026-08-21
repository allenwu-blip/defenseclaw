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

package gateway

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHandleSkillScanRejectsBundledSystemSkillBeforeScanner(t *testing.T) {
	codexHome := filepath.Join(t.TempDir(), "codex-home")
	t.Setenv("CODEX_HOME", codexHome)
	target := filepath.Join(codexHome, "skills", ".system", "imagegen")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(skillScanRequest{Target: target, Name: "imagegen"})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/skill/scan", bytes.NewReader(body))
	w := httptest.NewRecorder()

	(&APIServer{}).handleSkillScan(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want %d; body=%s", w.Code, http.StatusConflict, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "discovery-only") {
		t.Fatalf("response = %q, want bundled discovery-only refusal", w.Body.String())
	}
}

func TestBundledSkillScanPathDoesNotTrustArbitrarySystemDirectory(t *testing.T) {
	t.Setenv("CODEX_HOME", filepath.Join(t.TempDir(), "codex-home"))
	target := filepath.Join(t.TempDir(), "skills", ".system", "operator-skill")
	if isBundledSkillScanPath(target) {
		t.Fatalf("arbitrary .system path was incorrectly exempted: %s", target)
	}
}
