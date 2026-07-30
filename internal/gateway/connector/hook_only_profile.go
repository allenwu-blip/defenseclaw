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

package connector

import (
	"fmt"
	"strings"
)

func hookOnlyProfileMapVerdict(in HookVerdictInput) HookVerdictOutput {
	raw := normalizedGuardrailAction(in.RawAction)
	if raw == "" {
		raw = "allow"
	}
	if in.Mode != "action" {
		return HookVerdictOutput{Action: "allow", WouldBlock: raw == "block"}
	}
	switch raw {
	case "block":
		if in.Caps.CanBlock && eventInProfile(in.Event, in.Caps.BlockEvents) {
			return HookVerdictOutput{Action: "block", WouldBlock: false}
		}
		return HookVerdictOutput{Action: "allow", WouldBlock: true}
	case "confirm":
		if in.Caps.CanAskNative && eventInProfile(in.Event, in.Caps.AskEvents) {
			return HookVerdictOutput{Action: "confirm", WouldBlock: false}
		}
		return HookVerdictOutput{Action: "alert", WouldBlock: false}
	default:
		return HookVerdictOutput{Action: raw, WouldBlock: false}
	}
}

func hookOnlyProfileRespond(in HookRespondInput) HookRespondOutput {
	reason := connectorReasonForProfile(in.Req.ConnectorName, in.Action, in.Req.ToolName, in.Reason)
	var output map[string]interface{}
	switch in.Req.ConnectorName {
	case "hermes":
		// Hermes shell-hook lifecycle (cli-config.yaml `hooks:` block):
		//
		//	pre_llm_call     → inspect prompt; inject {"context":...}
		//	pre_tool_call    → inspect tool args; BLOCK (only blockable event)
		//	post_tool_call   → inspect tool output (observe)
		//	post_llm_call    → inspect model output (observe)
		//	on_session_*     → lifecycle telemetry (observe)
		//	subagent_start/stop → delegate-task telemetry (observe)
		//
		// Hermes reads a blocking stdout response only for
		// pre_tool_call and a {"context":...} injection for
		// pre_llm_call; it ignores the stdout of every other event, so
		// those return a nil body. Hermes accepts both
		// {"action":"block","message"} (its canonical shape) and
		// {"decision":"block","reason"} (the Claude-Code style it
		// normalizes internally); we emit the latter for wire parity
		// with the legacy shaper (hookOutputFor) and the pinned
		// hermes/verdict-blocked golden. Confirm verdicts fall through
		// to the shared {"systemMessage":...} epilogue below (hermes
		// has no native ask surface).
		if in.Action == "block" {
			output = map[string]interface{}{"decision": "block", "reason": reason}
		} else if canonicalHookEvent(in.Req.HookEventName) == "prellmcall" && in.AdditionalContext != "" {
			output = map[string]interface{}{"context": in.AdditionalContext}
		}
	case "cursor":
		output = cursorHookOutputForProfile(in.Req.HookEventName, in.Action, reason, in.AdditionalContext)
	case "windsurf":
		if in.Action == "block" {
			output = map[string]interface{}{"message": reason}
		}
	case "geminicli":
		if in.Action == "block" {
			output = map[string]interface{}{"decision": "deny", "reason": reason}
		} else if in.Action == "alert" && in.AdditionalContext != "" {
			output = map[string]interface{}{
				"decision":      "allow",
				"systemMessage": in.AdditionalContext,
			}
		}
	case "copilot":
		output = copilotHookOutputForProfile(in.Req.HookEventName, in.Action, in.RawAction, reason, in.AdditionalContext)
	case "openhands":
		if in.Action == "block" {
			output = map[string]interface{}{"decision": "deny", "reason": reason}
		} else if (in.Action == "alert" || in.RawAction == "confirm") && in.AdditionalContext != "" {
			output = map[string]interface{}{"additionalContext": in.AdditionalContext}
		}
	case "opencode":
		// The DefenseClaw bridge plugin reads .decision and throws on
		// "deny"/"block" to abort the tool. opencode has no hook-driven
		// ask or context-injection channel, so only block surfaces a
		// body; everything else is observe-only.
		if in.Action == "block" {
			output = map[string]interface{}{"decision": "deny", "reason": reason}
		}
	case "antigravity":
		output = antigravityHookOutputForProfile(in.Req.HookEventName, in.Action, in.RawAction, reason, in.AdditionalContext)
	case "omnigent":
		// The installed Python policy reads the unified top-level action
		// and translates allow/block/confirm to ALLOW/DENY/ASK. No nested
		// hook_output body is required by OmniGent's policy API.
		return HookRespondOutput{}
	}
	if output == nil && in.RawAction == "confirm" && in.AdditionalContext != "" && !in.Caps.CanAskNative {
		output = map[string]interface{}{"systemMessage": in.AdditionalContext}
	}
	return HookRespondOutput{FieldName: "hook_output", Output: output}
}

func cursorHookOutputForProfile(event, action, reason, additional string) map[string]interface{} {
	event = canonicalHookEvent(event)
	if event == "beforesubmitprompt" {
		if action == "block" {
			return map[string]interface{}{"continue": false, "user_message": reason, "agent_message": reason}
		}
		return map[string]interface{}{"continue": true}
	}
	if event == "stop" {
		// Cursor Stop hooks cannot veto termination. The only documented
		// response is followup_message, which starts a follow-up turn rather
		// than retroactively blocking the stop.
		message := additional
		if message == "" && action != "allow" {
			message = reason
		}
		if message != "" {
			return map[string]interface{}{"followup_message": message}
		}
		return map[string]interface{}{}
	}
	switch action {
	case "block":
		return map[string]interface{}{"continue": true, "permission": "deny", "user_message": reason, "agent_message": reason}
	case "confirm":
		return map[string]interface{}{"continue": true, "permission": "ask", "user_message": reason, "agent_message": reason}
	case "alert":
		if additional != "" {
			return map[string]interface{}{"continue": true, "permission": "allow", "agent_message": additional}
		}
	}
	switch event {
	case "pretooluse", "beforeshellexecution", "beforemcpexecution", "beforereadfile", "beforetabfileread":
		return map[string]interface{}{"continue": true, "permission": "allow"}
	default:
		return map[string]interface{}{"continue": true}
	}
}

// antigravityHookOutputForProfile renders only fields documented by
// https://antigravity.google/docs/hooks. PreToolUse is the sole hard policy
// boundary: synchronous stdout {"decision":"deny"} blocks the tool. No
// enforcement claim relies on the hook process exit code.
func antigravityHookOutputForProfile(event, action, _ string, reason, additional string) map[string]interface{} {
	switch canonicalHookEvent(event) {
	case "pretooluse":
		switch action {
		case "block":
			return map[string]interface{}{"decision": "deny", "reason": reason}
		case "confirm":
			return map[string]interface{}{"decision": "ask", "reason": reason}
		default:
			return map[string]interface{}{"decision": "allow"}
		}
	case "preinvocation", "postinvocation":
		if additional != "" {
			return map[string]interface{}{
				"injectSteps": []interface{}{
					map[string]interface{}{"ephemeralMessage": additional},
				},
			}
		}
		return map[string]interface{}{}
	case "posttooluse":
		return map[string]interface{}{}
	case "stop":
		// The documented "continue" decision re-enters the agent loop. That is
		// not a tool-execution block and DefenseClaw does not present it as one.
		return map[string]interface{}{"decision": "allow"}
	}
	return map[string]interface{}{}
}

func copilotHookOutputForProfile(event, action, rawAction, reason, additional string) map[string]interface{} {
	switch canonicalHookEvent(event) {
	case "pretooluse":
		switch action {
		case "confirm":
			return map[string]interface{}{"permissionDecision": "ask", "permissionDecisionReason": reason}
		case "block":
			return map[string]interface{}{"permissionDecision": "deny", "permissionDecisionReason": reason}
		}
	case "permissionrequest":
		if action == "block" {
			return map[string]interface{}{"behavior": "deny", "message": reason, "interrupt": true}
		}
	case "agentstop", "stop", "subagentstop":
		if action == "block" {
			return map[string]interface{}{"decision": "block", "reason": reason}
		}
	case "posttoolusefailure", "notification":
		if additional != "" {
			return map[string]interface{}{"additionalContext": additional}
		}
	}
	if rawAction == "confirm" && additional != "" {
		return map[string]interface{}{"additionalContext": additional}
	}
	return nil
}

func connectorReasonForProfile(connectorName, action, tool, reason string) string {
	if r := strings.TrimSpace(reason); r != "" {
		return r
	}
	tool = strings.TrimSpace(tool)
	switch action {
	case "block":
		if tool == "" {
			return "DefenseClaw blocked this action. Run `defenseclaw mcp list` or `skill list` to review approved assets."
		}
		return fmt.Sprintf("DefenseClaw blocked %s. Run `defenseclaw mcp list` or `skill list` to review approved assets.", tool)
	case "confirm":
		if tool == "" {
			return "DefenseClaw needs your approval before this action can run."
		}
		return fmt.Sprintf("DefenseClaw needs your approval before %s can run.", tool)
	case "alert", "allow_with_warning":
		if tool == "" {
			return "DefenseClaw flagged this action with a warning."
		}
		return fmt.Sprintf("DefenseClaw flagged %s with a warning.", tool)
	default:
		return fmt.Sprintf("Allowed by DefenseClaw %s policy.", connectorName)
	}
}
