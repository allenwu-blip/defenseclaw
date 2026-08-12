// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// SPDX-License-Identifier: Apache-2.0

//go:build windows

package managed

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/windows"
)

// cmidLibraryName is the Cloud Management identity library the managed
// cloud auth provider loads to mint bearer tokens.
const cmidLibraryName = "cmidapi.dll"

// Secure Client nests the library under two independent version
// directories and then splits it by architecture:
//
//	CM\<cm version>\CMID\<cmid version>\<arch>\cmidapi.dll
//
// Both versions move with Secure Client upgrades that DefenseClaw does
// not participate in, so the path cannot be baked in at install time.
const (
	cmidVendorRelativeRoot = `Cisco\Cisco Secure Client\CM`
	cmidNestedDirectory    = "CMID"
)

// DiscoverCMIDLibrary returns the newest Cloud Management identity
// library present on this machine, or "" when Secure Client has not
// installed one. Callers treat the empty result as "no override" and
// leave the provider to its own default.
func DiscoverCMIDLibrary() string {
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, windows.KF_FLAG_DEFAULT)
	if err != nil {
		return ""
	}
	return discoverCMIDLibraryIn(filepath.Join(programFiles, cmidVendorRelativeRoot), cmidArchDirectory())
}

// cmidArchDirectory maps the running architecture onto the leaf
// directory Secure Client ships it under.
func cmidArchDirectory() string {
	if runtime.GOARCH == "arm64" {
		return "arm64"
	}
	return "x64"
}

// discoverCMIDLibraryIn walks CM\<version>\CMID\<version>\<arch> newest
// first and returns the first library that exists, so a leftover older
// tree cannot pin the gateway to a stale library.
func discoverCMIDLibraryIn(cmRoot, arch string) string {
	for _, cmVersion := range versionDirectoriesNewestFirst(cmRoot) {
		cmidRoot := filepath.Join(cmRoot, cmVersion, cmidNestedDirectory)
		for _, cmidVersion := range versionDirectoriesNewestFirst(cmidRoot) {
			candidate := filepath.Join(cmidRoot, cmidVersion, arch, cmidLibraryName)
			if info, err := os.Lstat(candidate); err == nil && info.Mode().IsRegular() {
				return candidate
			}
		}
	}
	return ""
}

// versionDirectoriesNewestFirst lists the immediate subdirectories of
// root ordered by descending version. Names that do not parse as dotted
// numbers sort last so a stray directory cannot outrank a real version.
func versionDirectoriesNewestFirst(root string) []string {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		// Lstat rather than the DirEntry type so a reparse point posing
		// as a version directory cannot redirect the search off the
		// Secure Client tree.
		info, err := os.Lstat(filepath.Join(root, entry.Name()))
		if err != nil || !info.IsDir() {
			continue
		}
		names = append(names, entry.Name())
	}
	sortVersionsDescending(names)
	return names
}

func sortVersionsDescending(names []string) {
	// Insertion sort: these directories number in the single digits.
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && compareVersions(names[j-1], names[j]) < 0; j-- {
			names[j-1], names[j] = names[j], names[j-1]
		}
	}
}

// compareVersions orders two dotted version strings, returning a
// positive number when a is newer. Unparsable components compare as
// older than any number.
func compareVersions(a, b string) int {
	left := strings.Split(a, ".")
	right := strings.Split(b, ".")
	for i := 0; i < len(left) || i < len(right); i++ {
		if diff := versionComponent(left, i) - versionComponent(right, i); diff != 0 {
			return diff
		}
	}
	return strings.Compare(a, b)
}

func versionComponent(parts []string, index int) int {
	if index >= len(parts) {
		return 0
	}
	value, err := strconv.Atoi(parts[index])
	if err != nil {
		return -1
	}
	return value
}
