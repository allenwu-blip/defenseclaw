// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package connector

import (
	"errors"
	"fmt"

	"golang.org/x/sys/windows"
)

// windowsEffectiveUserSID is the single identity every per-user artifact in this
// package is created under and validated against. Creator and validator must
// read the same token or they disagree about every artifact they exchange.
var windowsEffectiveUserSID = defaultWindowsEffectiveUserSID

// defaultWindowsEffectiveUserSID returns the impersonated thread user when one
// is installed, and the process user otherwise.
//
// Windows takes a new object's owner from the effective token, which is the
// thread token whenever one is installed. The enterprise guardian is a
// LocalSystem process that mutates per-user paths under an exact target-user
// thread token, so its process token names the wrong principal for anything it
// creates inside a profile. Callers with no thread token read the same value
// either way.
func defaultWindowsEffectiveUserSID() (*windows.SID, error) {
	var token windows.Token
	err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &token)
	if err == nil {
		defer token.Close()
		user, userErr := token.GetTokenUser()
		if userErr != nil {
			return nil, userErr
		}
		if user == nil || user.User.Sid == nil {
			return nil, fmt.Errorf("effective Windows thread token has no user SID")
		}
		return user.User.Sid.Copy()
	}
	if !errors.Is(err, windows.ERROR_NO_TOKEN) {
		return nil, err
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	if user == nil || user.User.Sid == nil {
		return nil, fmt.Errorf("Windows process token has no user SID")
	}
	return user.User.Sid.Copy()
}
