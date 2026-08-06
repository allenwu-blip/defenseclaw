// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package connector

import (
	"testing"

	"golang.org/x/sys/windows"
)

// programDataUsersMask is the mask stock Windows grants BUILTIN\Users on
// C:\ProgramData via (A;CI;DCLCRPCR;;;BU): add-file, append, write-EA and
// write-attributes. Every managed state root sits beneath that directory.
const programDataUsersMask windows.ACCESS_MASK = 0x116

func TestHookAPIWindowsWriteLikeAccessAncestorAllowsStockProgramData(t *testing.T) {
	if hookAPIWindowsWriteLikeAccess(programDataUsersMask, false) {
		t.Fatal("stock C:\\ProgramData Users ACE rejected as an ancestor; the gateway cannot start on a default Windows host")
	}
	if !hookAPIWindowsWriteLikeAccess(programDataUsersMask, true) {
		t.Fatal("token directory must still reject create and write-attribute rights")
	}
}

func TestHookAPIWindowsWriteLikeAccessAncestorRejectsReplacement(t *testing.T) {
	const fileDeleteChild windows.ACCESS_MASK = 0x00000040
	for name, mask := range map[string]windows.ACCESS_MASK{
		"delete":       windows.DELETE,
		"delete_child": fileDeleteChild,
		"write_dac":    windows.WRITE_DAC,
		"write_owner":  windows.WRITE_OWNER,
		"generic_all":  windows.GENERIC_ALL,
		"generic_writ": windows.GENERIC_WRITE,
	} {
		if !hookAPIWindowsWriteLikeAccess(mask, false) {
			t.Errorf("%s must make an ancestor untrusted", name)
		}
	}
}