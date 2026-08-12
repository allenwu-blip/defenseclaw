// Copyright 2026 Cisco Systems, Inc. and its affiliates
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// SPDX-License-Identifier: Apache-2.0

//go:build !windows

package managed

// DiscoverCMIDLibrary has nothing to find off Windows: the version-nested
// Cloud Management layout it walks is a Secure Client for Windows shape,
// and every other platform's provider resolves its own library.
func DiscoverCMIDLibrary() string { return "" }
