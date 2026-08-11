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

import Foundation

@main
enum MainWindowLifecycleContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: MainWindowLifecycleContractTests <repository-root>\n", stderr)
            exit(2)
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let appSource = try source(
            at: root.appendingPathComponent("DefenseClawMac/App/DefenseClawApp.swift")
        )
        let popoverSource = try source(
            at: root.appendingPathComponent("DefenseClawMac/Features/MenuBarPopover.swift")
        )

        expect(appSource.contains(#"Window("DefenseClaw", id: "main")"#),
               "the primary dashboard must use a singleton Window scene")
        expect(!appSource.contains(#"WindowGroup("DefenseClaw", id: "main")"#),
               "the primary dashboard must not use a multi-instance WindowGroup")
        expect(appSource.contains("CommandGroup(replacing: .newItem) { }"),
               "the New Window command must remain disabled")

        let helper = try functionBody(named: "openMainWindow", in: popoverSource)
        expect(helper.contains("AppDelegate.prepareForMainWindowPresentation()"),
               "the menu action must activate the app before presenting the dashboard")
        expect(helper.components(separatedBy: #"openWindow(id: "main")"#).count - 1 == 1,
               "the menu action must issue exactly one SwiftUI window request")
        expect(!helper.contains("AppDelegate.openMainWindow()"),
               "the menu action must not combine AppKit and SwiftUI open operations")

        print("MainWindowLifecycleContractTests passed")
    }

    private static func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func functionBody(named name: String, in source: String) throws -> String {
        guard let start = source.range(of: "private func \(name)() {") else {
            throw TestError("could not find \(name) helper")
        }

        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start.upperBound..<index])
                }
            default: break
            }
            index = source.index(after: index)
        }
        throw TestError("could not parse \(name) helper")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
