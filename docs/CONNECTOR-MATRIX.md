# DefenseClaw — Connector Matrix

This page is the canonical, version-controlled reference for which features
are wired across each connector and, importantly, which gaps are **by
design** versus which are still pending implementation.

For the historical change log of how each row got to its current state, see
[`PR141-MATRIX-UPDATE.md`](PR141-MATRIX-UPDATE.md).

---

## At a glance

| Feature                     | OpenClaw | ZeptoClaw | Claude Code | Codex | Hermes | Cursor | Windsurf | Gemini CLI | Copilot CLI | OpenHands | Antigravity | OpenCode | OmniGent |
| --------------------------- | -------- | --------- | ----------- | ----- | ------ | ------ | -------- | ---------- | ----------- | --------- | ----------- | -------- | -------- |
| LLM traffic interception    | OK       | OK        | n/a         | n/a   | n/a    | n/a    | n/a      | n/a        | n/a         | n/a       | n/a         | n/a      | n/a      |
| Proxy-side response scan    | OK       | OK        | n/a         | n/a   | n/a    | n/a    | n/a      | n/a        | n/a         | n/a       | n/a         | n/a      | n/a      |
| Hook telemetry              | OK       | n/a*      | OK          | OK    | OK     | OK     | OK       | OK         | OK          | OK        | OK          | OK       | OK       |
| Hook `mode=action` blocking | OK       | n/a*      | OK          | partial | partial | partial | partial | partial    | partial     | partial   | partial     | partial  | OK       |
| Native human approval       | brokered | n/a       | PreToolUse  | no    | no     | event-specific | no | no | preToolUse | no        | PreToolUse  | no       | ASK      |
| Subprocess enforcement      | OK       | OK        | OK          | OK    | no     | no     | no       | no         | no          | no        | no          | no       | no       |
| Skill scan / list / enable  | OK       | OK        | OK          | OK    | skills | skills/rules | no skills | skills | skills/rules | skills | skills/rules | no skills | no skills |
| Watcher (skills + plugins)  | OK       | OK        | OK          | OK    | skills/plugins | skills | discovery | skills/extensions | skills | skills | skills/plugins | no | no |
| Native OTLP ingest          | OK       | n/a       | OK          | OK    | hook-only | hook-only | hook-only | OK | env-opt-in | hook-only | hook-only | hook-only | env-opt-in |

`*` = "not applicable" because the host agent has no schema slot for
external-script hook invocation. See **By-design connector limitations**
below for the architectural reason and how the security guarantee is
preserved without it.

The Hermes, Cursor, Windsurf, Gemini CLI, Copilot CLI, OpenHands, Antigravity, OpenCode, and OmniGent connectors do not
redirect LLM traffic through the proxy in v1. They are still first-class
connectors with explicit hook, MCP, skill/rule/plugin/agent, CodeGuard, and
telemetry capability rows where the vendor has documented local surfaces.

### OmniGent custom-policy setup

OmniGent integrates through its documented custom Python policy API rather
than a command hook. On POSIX shells, run:

```bash
defenseclaw setup omnigent --mode action --yes
omnigent server --config "${OMNIGENT_CONFIG_HOME:-$HOME/.omnigent}/config.yaml"
```

OmniGent connector setup is not supported on native Windows. Its terminal
runner requires `tmux`, its documented OS-sandbox backends are Linux/macOS,
and its Windows desktop application is not yet available. DefenseClaw does not
add a WSL implementation; use this connector on macOS/Linux.

`~/.omnigent/config.yaml` is the default. When `OMNIGENT_CONFIG_HOME` is set,
both OmniGent and DefenseClaw use `OMNIGENT_CONFIG_HOME/config.yaml` instead
(`$OMNIGENT_CONFIG_HOME/config.yaml` on POSIX or
`$env:OMNIGENT_CONFIG_HOME\config.yaml` in PowerShell).

Setup installs an owner-only policy module under
`~/.defenseclaw/hooks/defenseclaw_omnigent_policy.py`, adds its directory to
the OmniGent CLI environment through `defenseclaw_omnigent.pth`, registers
`defenseclaw_omnigent_policy` in `policy_modules`, and activates the
`defenseclaw_guardrail` server-wide policy. Restart OmniGent after setup so it
reloads the module and policy registry. Managed backups restore the original
YAML and Python environment files on connector teardown. OmniGent policy
events map as follows: `request` → `UserPromptSubmit`, `tool_call` →
`PreToolUse`, `tool_result` → `PostToolUse`, `response` →
`AfterAgentResponse`, `llm_request` → `BeforeModel`, and `llm_response` →
`AfterModel`. DefenseClaw verdicts map back to OmniGent `ALLOW`, `ASK`, and
`DENY`. OmniGent can park `request`, `tool_call`, and `llm_request` for native
`ASK` approval; post-action phases cannot pause cleanly and use DefenseClaw's
explicit confirm fallback. The bridge forwards an active OpenTelemetry W3C
trace context when one exists.

OmniGent also honors the standard OpenTelemetry process environment variables,
but this channel is not activated by connector setup. Export the variables in
the process that starts OmniGent.
Point `OTEL_EXPORTER_OTLP_ENDPOINT` at the DefenseClaw gateway, use
`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, and provide the DefenseClaw source,
client, and token headers through `OTEL_EXPORTER_OTLP_HEADERS`. Logs and metrics
are available with OmniGent's base install; native traces require its optional
`tracing` extra. DefenseClaw reports these variables but does not modify shell
startup files. Hook telemetry remains available without native OTLP.

### Observability dimension (multi-connector)

Every hook connector emits a connector dimension on all telemetry rails, so a
single gateway serving several connectors at once can be sliced per connector:
the OTel metric label `connector`, the span/log attribute
`defenseclaw.connector.source`, and the first-class `connector` field on audit
rows / Splunk HEC / OTLP-ingest rows (plus `structured.connector` on hook
rows). When more than one connector is active, `claw.mode` (and the OTel
resource attribute `defenseclaw.claw.mode`) is set to `multi`. Per-connector
*guardrail policy* lives under `guardrail.connectors.<name>` (hook connectors
only; proxy connectors can't be multi peers). The egress **firewall** is the
one cross-connector exception: it is global by design — a single host-wide
ruleset filtering by destination, with per-connector allowed hosts merged into
one allowlist at boot (see [`ARCHITECTURE.md` → Firewall scope](ARCHITECTURE.md)
and [`OBSERVABILITY-CONTRACT.md` → Connector dimension fields](OBSERVABILITY-CONTRACT.md)).

## Custom-provider enforcement (LLM traffic mode)

Provider resolution is global, but whether a [custom provider](/docs/setup/unified-llm-key)
touches the *agent* is per-connector. Each connector reports an
`llm_traffic_mode` on `GET /v1/connectors` (and in `ConnectorCapabilities`):

| Connector class | `llm_traffic_mode` | A bound custom provider… |
| --- | --- | --- |
| OpenClaw, ZeptoClaw | `proxy` | is **enforced** on the agent's model traffic (agent upstream, judge, or both) |
| every hook connector (Claude Code, Codex, Hermes, Cursor, Windsurf, Gemini CLI, Copilot, OpenHands, Antigravity, OpenCode, OmniGent) | `hooks-only` | configures DefenseClaw's **judge/aux model only** — the agent's own model calls are never routed through or inspected |

The CLI states this when binding (`setup llm`) and when listing
(`setup provider list`), so an operator can't silently attach a custom provider
to a hook connector believing it changes the agent's model.

## Platform support

Support status is about the complete DefenseClaw integration on the named host,
not merely whether the upstream agent has some Windows build. `preview` remains
selectable with an explicit warning. `not certified` means cross-platform code
exists but is not an end-user Windows contract; both `not certified` and
`unsupported` are hidden from Windows pickers and rejected by scripted/direct
setup with the reason below.

The current Windows product scope is **native Windows only**. WSL does not turn
a connector into a Windows-supported connector: the agent, hook/custom-policy
surface, DefenseClaw entrypoint, configuration paths, and teardown must all run
natively. WSL findings are recorded separately below for planning and do not
represent DefenseClaw Windows support or release certification.

| Connector | macOS | Linux | Native Windows | Windows reason |
| --------- | ----- | ----- | -------------- | -------------- |
| Codex | supported | supported | supported | Current Codex releases run natively on Windows and expose Windows-specific hook commands; DefenseClaw uses its native hook entrypoint. |
| Claude Code | supported | supported | supported | Anthropic documents direct PowerShell/CMD installation and native command hooks. Git for Windows is recommended, not required; Claude Code uses its PowerShell tool when Git Bash is absent. |
| Cursor | supported | supported | **not certified** (preview) | Cursor publishes a native Windows Agent installer and native desktop installers. DefenseClaw registers `%USERPROFILE%\.cursor\hooks.json` with a synchronous PowerShell adapter and native hook runtime; integrated packaged and official-client validation is still pending. |
| Windsurf | supported | supported | **not certified** | Windows setup code exists, but the DefenseClaw native release contract does not certify it. |
| Gemini CLI | supported (continuing paid/enterprise product) | supported (continuing paid/enterprise product) | **not certified** | Native Windows and the DefenseClaw adapter exist, but credentialed official-client certification is still required. Gemini CLI now serves enterprise, Google Cloud, and paid API-key users only. |
| Claude Code | supported | supported | supported | Native Windows with Git for Windows is documented and supports command hooks. |
| Cursor | supported | supported | **not certified** | Windows setup code exists, but the DefenseClaw native release contract does not certify it. Cursor CLI remains WSL-only. |
| Windsurf | supported | supported | **preview** | Devin Desktop (Windsurf) ships native Windows x64, and its documented `powershell` hook field runs via `powershell -Command`. DefenseClaw implements a synchronous native PowerShell adapter to the exact packaged hook executable; packaged and interactive official-client certification is still pending. |
| Gemini CLI | supported | supported | **not certified** | Windows setup code exists, but the DefenseClaw native release contract does not certify it. |
| Copilot CLI | supported | supported | **not certified** | Windows setup code exists, but the DefenseClaw native release contract does not certify it. |
| Antigravity | supported | supported | **not certified** | Google publishes native Windows x64/ARM64 clients and the implementation targets CLI 1.1.8+, but integrated packaged and official-client validation is still pending. |
| OpenCode | supported | supported | **not certified** | Windows setup code exists, but the DefenseClaw native release contract does not certify it. |
| Hermes | supported | supported | **not certified** | Upstream Windows availability does not substitute for DefenseClaw native release certification. |
| OpenHands | supported | supported | unsupported | OpenHands CLI explicitly requires WSL; DefenseClaw has no WSL connector implementation. |
| OmniGent | supported | supported | unsupported | The terminal path requires `tmux`, the OS sandbox documents Linux/macOS backends, and the Windows desktop app is still pending. |
| OpenClaw | supported | supported | unsupported | OpenClaw itself has a native path, but DefenseClaw's connector requires the local guardrail-proxy lifecycle, which DefenseClaw does not host on Windows. |
| ZeptoClaw | supported | supported | unsupported | Upstream publishes macOS/Linux support, and the DefenseClaw connector also requires the unavailable Windows guardrail proxy. |

Do not run the not-certified connector setup aliases as a workaround. Their
presence in one cross-platform CLI does not override the Windows platform gate.
The end-user source of truth is the
[native Windows guide](https://cisco-ai-defense.github.io/defenseclaw/docs/get-started/windows/).

### WSL research (out of current Windows scope)

This table answers whether upstream explicitly documents or recommends a WSL
path. It is research input only: DefenseClaw currently tests and ships the
Windows connector surface against native Windows, not a Windows-to-WSL bridge.
When upstream documents Linux but does not explicitly document WSL, the result
is `not separately documented` rather than an inferred support promise.

| Hook connector | Upstream WSL position | Current DefenseClaw Windows decision |
| -------------- | --------------------- | ------------------------------------ |
| Codex | WSL2 is documented; WSL1 is no longer supported starting with Codex 0.115. | Native Windows supported; WSL is out of scope. |
| Claude Code | WSL1 and WSL2 are documented alternatives to the direct native Windows installation. | Native Windows supported; WSL is out of scope. |
| Hermes | Linux/WSL2 is upstream Tier 1 and tested on current WSL2; it is a separate installation from native Windows. | Not certified by DefenseClaw on native Windows; WSL is out of scope. |
| Cursor | Cursor documents both native Windows Agent installation and WSL installation. | Native Windows Agent/IDE hooks are available as a DefenseClaw preview; WSL remains out of scope. |
| Windsurf | Hook docs publish Linux/WSL configuration locations as well as native Windows locations. | Not certified by DefenseClaw on native Windows; WSL is out of scope. |
| Gemini CLI | The supported OS matrix includes native Windows 11 24H2+ with PowerShell and Node.js 20+; no compatibility layer is required. | Native adapter implemented but not certified by DefenseClaw; WSL and other compatibility layers are out of scope. |
| Copilot CLI | Direct PowerShell execution and the version-1 `powershell` hook field are documented for Windows; official 1.0.76 Windows x64/ARM64 ZIP and MSI assets were current on 2026-07-30. | Upstream-eligible and implemented behind the platform gate, but not certified by DefenseClaw until packaged and real-client Windows evidence passes; no WSL support claim. Copilot 1.0.76 also documents that per-path sandbox denials cannot be enforced on Windows. |
| Cursor | Cursor CLI is supported on Windows through WSL; Cursor IDE hooks run on native Windows. | Native IDE hooks are not certified by DefenseClaw; the WSL-only CLI is not configured. |
| Windsurf | Hook docs publish Linux/WSL configuration locations as well as native Windows locations. | Native Windows preview through the documented PowerShell hook transport; WSL remains out of scope and certification is pending. |
| Gemini CLI | WSL is mentioned as a Unix-compatibility option, but the supported OS matrix already includes native Windows. | Not certified by DefenseClaw on native Windows; WSL is out of scope. |
| Copilot CLI | Hooks are documented for Windows, Linux, and macOS; WSL is not a separate hook target. | Not certified by DefenseClaw on native Windows; no WSL support claim. |
| OpenHands | The CLI explicitly requires WSL on Windows; native Windows is not officially supported. | Unsupported on Windows because WSL-only does not meet the native requirement. |
| Antigravity | Native Windows CLI/app downloads and local hooks are documented; WSL is not a separate hook target. | Native Windows x64 implementation is not yet certified; WSL is out of scope. |
| OpenCode | Direct Windows execution is available, while upstream recommends WSL for the best experience. | The JavaScript bridge is not certified by DefenseClaw on native Windows; WSL is out of scope. |
| OmniGent | Linux terminal and sandbox prerequisites are documented; WSL is not explicitly supported as a Windows product path. | Unsupported on native Windows; no WSL connector is implemented or certified. |

Evidence checked 2026-07-30 against the current upstream documentation:
[Codex install](https://github.com/openai/codex#quickstart),
[Codex Windows](https://developers.openai.com/codex/windows),
[Codex hooks](https://developers.openai.com/codex/hooks),
[Claude Code setup](https://code.claude.com/docs/en/setup),
[Claude Code hooks](https://code.claude.com/docs/en/hooks),
[Claude Code settings](https://code.claude.com/docs/en/settings),
[Claude Code MCP](https://code.claude.com/docs/en/mcp),
[Cursor CLI installation](https://docs.cursor.com/en/cli/installation),
[Cursor downloads](https://cursor.com/download),
[Cursor hooks](https://cursor.com/docs/hooks),
[Cursor CLI changelog](https://cursor.com/docs/cli/changelog),
[Windsurf Cascade hooks](https://docs.windsurf.com/windsurf/cascade/hooks),
[Gemini CLI installation](https://geminicli.com/docs/get-started/installation/),
[Gemini CLI authentication](https://geminicli.com/docs/get-started/authentication/),
[Gemini CLI configuration](https://geminicli.com/docs/reference/configuration/),
[Windsurf/Devin Desktop download](https://devin.ai/download),
[Windsurf/Devin Desktop install and uninstall](https://docs.devin.ai/desktop/getting-started),
[Windsurf Cascade hooks](https://docs.devin.ai/desktop/cascade/hooks),
[Windsurf/Devin Desktop changelog](https://docs.devin.ai/desktop/changelog),
[Gemini CLI hooks](https://geminicli.com/docs/hooks/reference/),
[Gemini CLI transition announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/),
[Gemini CLI to Antigravity migration](https://antigravity.google/docs/cli/gcli-migration),
[Copilot CLI hooks](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks),
[Copilot CLI hook reference](https://docs.github.com/en/copilot/reference/hooks-reference),
[Copilot CLI Windows installation](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli),
[Copilot CLI releases](https://github.com/github/copilot-cli/releases),
[Antigravity hooks](https://antigravity.google/docs/hooks),
[OpenCode Windows](https://opencode.ai/docs/windows-wsl/),
[OpenCode plugins](https://opencode.ai/docs/plugins/),
[Hermes platform support](https://hermes-agent.nousresearch.com/docs/getting-started/platform-support),
[Hermes native Windows guide](https://hermes-agent.nousresearch.com/docs/user-guide/windows-native),
[OpenHands CLI quick start](https://docs.openhands.dev/openhands/usage/cli/quick-start),
[OmniGent terminal](https://omnigent.ai/docs/interact/terminal),
[OmniGent sandbox](https://omnigent.ai/docs/policies/os-sandbox),
[OmniGent desktop](https://omnigent.ai/docs/interact/desktop), and
[ZeptoClaw installation](https://zeptoclaw.com/docs/getting-started/installation/).

Windows DefenseClaw is **hook-only**. The certified Codex and Claude Code
registrations invoke `defenseclaw-hook.exe` natively, without Git Bash, `jq`,
shell shims, or WSL. Cursor's native PowerShell adapter is preview-only until
integrated packaged and official-client validation passes. OpenCode's
cross-platform JavaScript bridge is not certified on native Windows. The Go
registry and Python `platform_support` module mirror the current
supported/preview/not-certified/unsupported statuses and reasons, pinned by
parity tests.
registrations invoke `defenseclaw-hook.exe` natively. Windsurf invokes a
generated native PowerShell adapter through its documented `powershell`
field; that adapter waits for the exact packaged executable and preserves JSON
stdin, stdout/stderr, and exit status. None of these paths uses Git Bash,
`jq`, a POSIX shell, or WSL. OpenCode's cross-platform JavaScript bridge is
not certified on native Windows. The Go registry and Python
`platform_support` module mirror the current
supported/not-certified/unsupported statuses and reasons, pinned by parity
tests.

## Versioned Hook Contracts

The machine-readable compatibility source lives at
[`cli/defenseclaw/inventory/hook_contracts.json`](../cli/defenseclaw/inventory/hook_contracts.json).
DefenseClaw setup refreshes `agent_discovery.json`, checks the installed
connector version against this manifest, and refuses unsupported hook
contracts in `mode=action`. Internal compatibility experiments do not create a
supported end-user contract.

After the gateway completes connector setup it writes
`<data_dir>/hook_contract_lock.json`. That lock records the current
installed connector version, normalized version, selected contract ID, hook
script version, script digests, and DefenseClaw build version so a later
doctor run can detect drift.

Setup allows unsupported or unverified hook connector versions in observe mode
with a warning. Action mode fails closed on that contract mismatch.

| Connector | Current compatibility gate | Supported connector versions | Hook contract / script | AID surfaces |
| --------- | -------------------------- | ---------------------------- | ---------------------- | ------------ |
| OpenClaw | proxy, not hook-gated | not gated by hook contract | n/a | proxy request/response surfaces |
| ZeptoClaw | proxy, not hook-gated | not gated by hook contract | n/a | proxy request/response surfaces |
| Codex | hook contract | `>=0.124.0` | `codex-hooks-v1` / `v6` | prompt, tool_call, tool_result |
| Claude Code | hook contract | `>=2.1.152` | `claudecode-hooks-v1` / `v7` | prompt, tool_call, tool_result, event_content |
| Hermes | hook contract | `>=0.11.0` | `hermes-hooks-v1` / `v6` | prompt, tool_call, tool_result, event_content |
| Cursor | hook contract | `>=1.7.0` | `cursor-hooks-v1` / `v8` | prompt, tool_call, tool_result |
| Windsurf | hook contract | `>=1.12.41` | `windsurf-hooks-v1` / `v6` | prompt, tool_call, tool_result |
| Gemini CLI | hook contract | `>=0.26.0` | `geminicli-hooks-v1` / `v7` | prompt, tool_call, tool_result |
| Copilot CLI | hook contract | `>=1.0.18` | `copilot-hooks-v1` / `v6` | prompt, tool_call, tool_result |
| OpenHands | hook contract | unversioned / documented hooks; tested with `OpenHands CLI 1.16.0` | `openhands-hooks-v1` / `v6` | prompt, tool_call, tool_result, event_content |
| Antigravity | hook contract | `>=1.1.8` | `antigravity-hooks-v2` / `v8` | tool_call, event_content |
| OpenCode | hook contract | unversioned / stable plugin API | `opencode-hooks-v1` / `v6` (JS bridge plugin) | tool_call, tool_result |
| OmniGent | hook contract | unversioned / documented custom-policy API | `omnigent-custom-policy-v1` / `v1` (Python policy bridge) | prompt, tool_call, tool_result, event_content |

No hook contract currently has a `max_exclusive` ceiling. We only add an upper
bound when an upstream release publishes a breaking hook change; otherwise,
future connector versions remain reproducible through the lock file and drift
checks instead of being blocked by a guessed major-version cap.

Version floors are evidence-backed from upstream release notes or current
vendor docs: Codex `0.124.0` is the stable-hooks release, Gemini CLI `0.26.0`
enabled hooks by default, Cursor `1.7.0` introduced beta hooks, Hermes
`0.11.0` added shell hooks for `pre_tool_call`, Windsurf `1.12.41` added user
prompt hooks to the Cascade pre-hook set, and Copilot CLI `1.0.18` is the first
release containing every event in the current DefenseClaw Copilot contract.
OpenHands uses the current documented `.openhands/hooks.json` contract, has
been validated with `OpenHands CLI 1.16.0`, and is accepted as unversioned
until upstream publishes a hook-version floor. DefenseClaw installs OpenHands
globally through `~/.openhands/hooks.json` by default and uses repo-local
`.openhands/hooks.json` only when a workspace is pinned.
Claude Code is pinned to the current documented hook surface captured at
`2.1.152`; older Claude Code versions exposed smaller event sets. The Claude
native-Windows evidence and hook contract were rechecked on 2026-07-30; see the
[Claude Code native Windows reference](reference/CLAUDE-CODE-WINDOWS.md).

## Hook Capability Matrix

| Connector | can_block | can_ask_native | ask_events | block_events | supports_fail_closed | scope | config_path |
| --------- | --------- | -------------- | ---------- | ------------ | -------------------- | ----- | ----------- |
| Claude Code | yes | yes | `PreToolUse` | 14 current lifecycle events; exact list is checked against `capability-matrix.json` | yes | user | `~/.claude/settings.json` |
| Codex | yes | no | none | `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` | yes | user | `~/.codex/config.toml` |
| Hermes | yes | no | none | `pre_tool_call` | no | user | `$HERMES_HOME/config.yaml`; defaults to `%LOCALAPPDATA%\hermes\config.yaml` on native Windows and `~/.hermes/config.yaml` elsewhere |
| Cursor | yes | yes | `beforeShellExecution`, `beforeMCPExecution` | `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead`, `beforeSubmitPrompt` | yes | user | `~/.cursor/hooks.json` (`%USERPROFILE%\.cursor\hooks.json` on Windows) |
| Windsurf | yes | no | none | `pre_user_prompt`, `pre_read_code`, `pre_write_code`, `pre_run_command`, `pre_mcp_tool_use` | no | user | `~/.codeium/windsurf/hooks.json` |
| Cursor | yes | yes | `beforeShellExecution`, `beforeMCPExecution` | documented pre-action hooks | yes | user | `~/.cursor/hooks.json` |
| Windsurf | yes | no | none | `pre_user_prompt`, `pre_read_code`, `pre_write_code`, `pre_run_command`, `pre_mcp_tool_use` | yes, through exit `2` only | user | `~/.codeium/windsurf/hooks.json` |
| Gemini CLI | yes | no | none | `BeforeAgent`, `BeforeModel`, `BeforeTool`, `AfterTool`, `AfterAgent` | yes | user | `~/.gemini/settings.json` |
| Copilot CLI | yes | yes | `preToolUse` | `preToolUse`, `permissionRequest`, `agentStop`, `subagentStop`, `postToolUseFailure` | no | user,workspace | `~/.copilot/hooks/defenseclaw.json` or `<workspace>/.github/hooks/defenseclaw.json` |
| OpenHands | yes | no | none | `pre_tool_use`, `user_prompt_submit`, `stop` | yes | user,workspace | `~/.openhands/hooks.json` or `<workspace>/.openhands/hooks.json` |
| Antigravity | yes | yes | `PreToolUse` | `PreToolUse` | no | user | `~/.gemini/config/hooks.json` |
| OpenCode | yes | no | none | `tool.execute.before` | yes | user | `~/.config/opencode/plugins/defenseclaw.js` (JS bridge plugin) |
| OmniGent | yes | yes | `UserPromptSubmit`, `PreToolUse`, `BeforeModel` | all six mapped policy phases | yes | user | `$OMNIGENT_CONFIG_HOME/config.yaml` when set, otherwise `~/.omnigent/config.yaml`, plus installed Python policy |

Gemini CLI and Antigravity share the `~/.gemini` parent directory but not
DefenseClaw ownership. Gemini lifecycle custody is limited to marked fields in
`~/.gemini/settings.json`, its connector-specific managed backup, and its
scoped OTLP token. Antigravity content under `~/.gemini/config/` and
`~/.gemini/antigravity-cli/`, plus unrelated Google credentials and agent
assets, is excluded from Gemini reconciliation, deferred uninstall, teardown,
and backup discovery. Native Setup passes the persisted `.gemini` directory
only through DefenseClaw's hidden maintenance `--config-home` binding; it does
not create a Gemini client environment override or delete the shared parent.

`confirm` verdicts are rendered as native ask only when the event is listed in
`ask_events`. Every other event takes its connector-specific alert, allow, or
context fallback immediately while preserving `raw_action: "confirm"` for
audit. The DefenseClaw TUI can review those records but cannot resume the call.

Gemini CLI registers all 11 documented lifecycle events. `SessionEnd` is
upstream best-effort and not awaited; `Notification` and `PreCompress` are
observation-only. The five events listed above are the declared block surfaces.
For policy decisions and DefenseClaw adapter failures, Gemini receives exit 0
with JSON `decision=allow|deny`; alert fallback may add the documented
`systemMessage` field to an allow response. This deliberately avoids the legacy
nonzero path, whose description in the hook reference differs from v0.53.0 source.
This guarantee begins after Gemini successfully spawns the adapter: host spawn
failures and host-enforced timeouts remain Gemini CLI behavior.

Cursor command hooks fail open by default, matching the vendor schema.
DefenseClaw writes `failClosed: true` only when action mode explicitly selects
the closed hook failure mode; then crashes, timeouts, and invalid JSON block.
Cursor accepts `ask` in the `preToolUse` output schema but does not enforce it;
only `beforeShellExecution` and `beforeMCPExecution` enforce native ask.
`sessionStart` and `sessionEnd` are fire-and-forget, and `stop` supports only a
follow-up message, so none of those lifecycle events is presented as a
synchronous enforcement gate.

## Local Surface Matrix

| Connector | MCP | Skills | Rules | Plugins / extensions | Agents | CodeGuard native assets |
| --------- | --- | ------ | ----- | -------------------- | ------ | ----------------------- |
| Claude Code | user/local `~/.claude.json`; project `<workspace>/.mcp.json` | `~/.claude/skills`, `<workspace>/.claude/skills` | user/project `CLAUDE.md` and `.claude/rules` surfaces | user cache under `~/.claude/plugins`; enablement is stored in scoped settings | `~/.claude/agents`, `<workspace>/.claude/agents` | opt-in skill or rule |
| Codex | `~/.codex/config.toml`, optional workspace `.mcp.json` | `~/.codex/skills`, optional workspace `.codex/skills` | `AGENTS.md` hierarchy | `~/.codex/plugins`, optional workspace plugin paths | built-in/subagent surfaces differ from Claude Code; no path equivalence assumed | opt-in skill |
| Hermes | `$HERMES_HOME/config.yaml` | `$HERMES_HOME/skills` | unsupported | `$HERMES_HOME/plugins` (`.hermes/plugins` workspace discovery only) | unsupported | opt-in skill |
| Cursor | `.cursor/mcp.json`, `~/.cursor/mcp.json` | `.cursor/skills`, `.agents/skills`, user equivalents | `.cursor/rules`, `AGENTS.md` | unsupported | unsupported | opt-in skill or rule |
| Windsurf | existing documented/user MCP paths only | unsupported | existing documented/user rules paths only | unsupported | unsupported | opt-in rule only when a rules path exists |
| Gemini CLI | `~/.gemini/settings.json` | `.gemini/skills`, `.agents/skills` | represented through skills/agents | `.gemini/extensions`, `~/.gemini/extensions` | `.gemini/agents`, `~/.gemini/agents` | opt-in skill |
| Copilot CLI | `~/.copilot/mcp-config.json`, optional workspace `.github/mcp.json`, `.mcp.json` | `~/.copilot/skills`, optional workspace `.github/skills`, `.agents/skills` | optional workspace `.github/instructions` | CLI marketplace/plugin flow | `~/.copilot/agents`, optional workspace `.github/agents` | opt-in skill or rule |
| OpenHands | `~/.openhands/mcp.json` | `~/.agents/skills`, `~/.openhands/skills/installed`, `~/.openhands/cache/skills/public-skills/skills` (`~/.openhands/skills`, `~/.openhands/microagents` discovery only; workspace equivalents with `--workspace`) | `AGENTS.md` discovery only when workspace-pinned | unsupported | unsupported | opt-in skill |
| Antigravity | `~/.gemini/config/mcp_config.json`, `<workspace>/.agents/mcp_config.json` (read/write); `<plugin>/mcp_config.json` discovery only | AgentSkills folder form read/write: `~/.gemini/config/skills/<skill>/SKILL.md`, `<workspace>/.agents/skills/<skill>/SKILL.md`; CLI direct `~/.gemini/antigravity-cli/skills/*.md` discovery only | `~/.gemini/GEMINI.md`, `<workspace>/.agents/rules/`, `<plugin>/rules/*.md` discovery only | `~/.gemini/config/plugins/<plugin>/`, `<workspace>/.agents/plugins/<plugin>/` install/list/scan/remove; `~/.gemini/antigravity-cli/plugins/<plugin>/` discovery/scan | plugin-contained `<plugin>/agents/` discovery only; standalone agents unsupported | opt-in skill |
| OpenCode | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) |
| OmniGent | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) | unsupported (v1) |

CodeGuard native assets are never installed by CLI startup, `init`, sandbox
setup, or sidecar setup. Operators must run `defenseclaw codeguard install`
explicitly. Existing valid CodeGuard assets are skipped, and existing
non-CodeGuard paths require `--replace`.

## Telemetry Matrix

| Connector | Native telemetry | DefenseClaw auth | Hook telemetry |
| --------- | ---------------- | ---------------- | -------------- |
| Codex | native logs/metrics/traces via OTLP HTTP from config.toml | connector-scoped loopback path token | notify/hook telemetry |
| Claude Code | native OTLP env in settings.json | header token | hook telemetry |
| Gemini CLI | native logs/metrics/traces in settings.json | loopback path token | hook telemetry |
| Copilot CLI | native traces/metrics via documented env vars | header token | hook telemetry |
| OpenHands | no documented native OTLP | header token | hook telemetry |
| OmniGent | optional logs/metrics via externally supplied OTLP env vars; traces with optional `tracing` extra | header token | hook-generated logs, spans, counters |
| Hermes / Cursor / Windsurf / OpenCode | no documented native OTLP | n/a | hook-generated logs, spans, counters |

---

## Live E2E coverage

The [`.github/workflows/connector-live-e2e.yml`](../.github/workflows/connector-live-e2e.yml)
workflow proves each hook connector end-to-end against real upstream agents
and flags when an upstream release breaks a hook. It is intentionally
separate from `e2e.yml` so it can go red on an upstream regression without
blocking the OpenClaw stack gate. The harness lives under
[`scripts/live-connector-e2e/`](../scripts/live-connector-e2e).

### Two layers

| Layer | What it proves | LLM? | Secrets? | OSes | When |
| ----- | -------------- | ---- | -------- | ---- | ---- |
| **A — Contract matrix** | Feeds golden stdin payloads into the *installed* hook entrypoint and asserts the gateway received the event, the verdict was shaped correctly, and teardown is clean. | no | no | linux, macos, windows | every run; fork-safe |
| **B — Live agent matrix** | Installs the real agent at its latest version, runs `defenseclaw setup`, drives lifecycle + forced tool calls through the real harness, and asserts observe / block / OTLP / teardown. | yes (deterministic prompts) | yes | per the reality matrix below | nightly + manual dispatch |

Layer A targets `~/.defenseclaw/hooks/<connector>-hook.sh` on Linux/macOS. On
Windows, Codex and Claude Code use the native hook runtime directly; Windsurf
uses the generated PowerShell adapter that synchronously launches the same
exact packaged runtime. All forward the payload to the local gateway, so every
assertion uses canonical SQLite event history regardless of OS. An explicit
JSONL destination may be tested separately, but it is not an implicit mirror
or the lifecycle contract authority.

Hooks are **harness-driven**, not LLM-driven: the agent fires
`SessionStart` / `PreToolUse` / etc. as a function of its lifecycle, so Layer B
only needs the model to run the one shell command it is explicitly told to.
Enforcement is proven with a filesystem **sentinel**: the allow probe runs a
benign command that creates a marker file; the block probe asks the agent to
read `/etc/shadow` (rule `PATH-ETC-SHADOW`, CRITICAL) — if the marker ever
appears, the command ran and the block regressed. Reading `/etc/shadow` is
harmless (permission denied) if a regression ever lets it through.

### Per-connector reality matrix (Layer B)

This live-driver inventory records test-harness reach, not release support.
Only cells explicitly marked certified carry the native Windows support
contract; an advisory or contract-only probe does not promote a connector.

| Connector | Linux | macOS | Windows | Live driver headless invocation | Notes |
| --------- | ----- | ----- | ------- | ------------------------------- | ----- |
| Codex | live | live | live\* (certified) | `codex exec --json --full-auto` | native OTLP asserted |
| Claude Code | live | live | live\* (certified) | `claude -p` | native OTLP asserted; native-ask is Layer A only |
| Gemini CLI | live driver (credential-deferred) | live driver (credential-deferred) | staged live driver (not certified) | `gemini -p -o json --approval-mode yolo` | driver asserts `BeforeTool` exit-0 JSON allow/block and native OTLP; certification requires eligible paid/enterprise credentials. Failures before adapter start, host launch/timeout behavior, and collapsed nonzero exits remain live-certification boundaries. |
| Cursor | live | live | live\* (preview; certification pending) | `agent -p --force` (`cursor-agent` compatibility alias) | native PowerShell contract coverage is implemented; integrated packaged and official-client validation is pending |
| Copilot CLI | live\* | live\* | live\* (not certified) | `copilot -p` | user-level hooks only; entitled token |
| OpenHands | live | — | — | `openhands --headless --json` | Docker runtime, Linux-only |
| OpenCode | contract-only | contract-only | contract-only (not certified) | — | JS bridge plugin (tool.execute.before blocks); live smoke pending |
| Hermes | contract-only | contract-only | contract-only (not certified) | — | Native Windows is upstream Tier 1, but DefenseClaw does not certify the connector there. |
| Windsurf | contract-only | contract-only | contract-only (preview; not certified) | — | no headless CLI/SDK; interactive native Windows client gate deferred |
| Antigravity | contract-only | contract-only | contract + native package validation pending (not certified) | `agy --dangerously-skip-permissions --print` on an authenticated runner | Google documents Windows Credential Manager/browser auth, not API-key bootstrap; real live E2E requires a pre-authenticated native Windows runner. |
| OmniGent | contract-only | contract-only | — | — | Native Windows connector unsupported; Python custom-policy bridge covered by local integration tests on supported hosts; live smoke pending |

`\*` = advisory cell (`continue-on-error`) until it goes consistently green.
All Windows live cells and every Copilot cell start advisory; they are promoted
to gating once stable. Contract-only connectors run Layer A on every OS and are
intentionally absent from Layer B.

> **Current rollout:** the nightly schedule runs **Layer A only**. Layer B is
> manual-dispatch-only and presently scoped to the connectors we can
> authenticate with Azure OpenAI / Amazon Bedrock — **Codex, Claude Code, and
> OpenHands**. **Gemini CLI, Cursor, and Copilot live cells are deferred** until
> their native keys (`GEMINI_API_KEY` or `GOOGLE_API_KEY`, `CURSOR_API_KEY`,
> `COPILOT_CLI_TOKEN`) are configured; Gemini credentials must belong to the
> continuing paid/enterprise audience. All three still get Layer A coverage in
> the meantime.

### Alternative LLM auth (Azure OpenAI / Amazon Bedrock)

The live drivers can source the model from a non-default backend. This only
changes where the agent's LLM traffic goes — the hook bus, verdicts, and OTLP
are unaffected, so hook coverage is identical. Selection is per backend, not
global: set the repo Variable (`DC_USE_AZURE` / `DC_USE_BEDROCK` = `1`) to make
it the nightly default, or flip the `use_azure` / `use_bedrock` dispatch toggle.

| Connector | Default | Azure OpenAI (`DC_USE_AZURE=1`) | Amazon Bedrock (`DC_USE_BEDROCK=1`) |
| --------- | ------- | ------------------------------- | ----------------------------------- |
| Codex | `OPENAI_API_KEY` | yes — seeds `[model_providers.azure]` in `~/.codex/config.toml` | no (Codex is OpenAI-only) |
| Claude Code | `ANTHROPIC_API_KEY` | no | yes — `CLAUDE_CODE_USE_BEDROCK=1` + AWS chain |
| OpenHands | `LLM_API_KEY` | yes — `azure/<deployment>` via LiteLLM | yes — `bedrock/<profile>` via LiteLLM (wins if both set) |
| Gemini CLI / Cursor / Copilot | native key | — | — |

Required inputs per backend:

- **Azure**: secret `AZURE_OPENAI_API_KEY`; Variables `AZURE_OPENAI_ENDPOINT`
  (resource URL), `AZURE_OPENAI_DEPLOYMENT` (used as the model id),
  optional `AZURE_OPENAI_API_VERSION` (OpenHands only; defaults to a recent
  preview). The deployment must be a model the connector supports (Codex needs
  a Responses-API-capable deployment).
- **Bedrock**: secret `AWS_BEARER_TOKEN_BEDROCK` *or* the pair
  `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (+ optional
  `AWS_SESSION_TOKEN`); Variable `AWS_REGION` (defaults to `us-east-1`).
  Optional model-id overrides: `CLAUDE_BEDROCK_MODEL`, `OPENHANDS_BEDROCK_MODEL`.

Gemini CLI, Cursor, and Copilot have **no** Azure/Bedrock substitute — they
require their native provider key (`GOOGLE_API_KEY`, `CURSOR_API_KEY`,
`COPILOT_CLI_TOKEN`) to run live.

### Version policy (alert-only)

The workflow is an **evidence engine, not an auto-bumper**. Each live cell
records the resolved upstream version into the job summary. On any live-cell
failure the `report` job opens or updates a GitHub issue labeled
`connector-regression` listing the failing connector / OS / event / version,
and links the uploaded log artifact. It never edits a version file.

Setting the highest approved version stays a deliberate human action:

1. A maintainer triages whether DefenseClaw's decode/map/respond needs a fix or
   the upstream agent changed its hook contract.
2. If DefenseClaw must drop support for the new release, raise `min_inclusive`
   or set `max_exclusive` in
   [`cli/defenseclaw/inventory/hook_contracts.json`](../cli/defenseclaw/inventory/hook_contracts.json)
   and [`internal/gateway/connector/hook_contract.go`](../internal/gateway/connector/hook_contract.go).
3. Once green again, record the validated version in
   [`cli/defenseclaw/inventory/validated_versions.json`](../cli/defenseclaw/inventory/validated_versions.json)
   (per connector × OS: `last_validated_version`, `last_validated_at`,
   `run_url`). This file is human-reviewed only; the workflow reads it for
   context but never writes it.

The runtime drift guard (`hook_contract_lock.json` + the action-mode
fail-closed behavior described above) is unchanged — this workflow is what
generates the evidence a maintainer uses to update the floors and ceilings.

---

## By-design connector limitations

These constraints come from each host's current extension surface. Proxy
connectors can enforce in the LLM data path; hook connectors can enforce only
on events the host actually emits and honors.

### 1. ZeptoClaw `before_tool` hook wiring is by design

- Source: [`internal/gateway/connector/zeptoclaw.go`](../internal/gateway/connector/zeptoclaw.go)
  near the `ZeptoClawConnector` doc comment.
- Why: ZeptoClaw's `HooksConfig.before_tool` is a **notification list**
  (in-process callback signal), shaped as `[]HookRule{Match, Action}` —
  structured objects, not script paths. There is no schema slot to say
  "run `/path/to/inspect-tool.sh` before this tool fires", and adding
  one is upstream's call.
- What replaces it: The proxy enforces the policy on the LLM response
  stream **before** the tool list reaches the agent. `ToolModeBoth` on
  the connector wires this. The proxy is the policy enforcement point;
  the agent never sees a disallowed `tool_calls` entry.
- What we still ship: Hook scripts under `DataDir/hooks` for subprocess
  enforcement (shim PATH) and as forward-compat artefacts in case
  ZeptoClaw ever grows external-script hooks.
- What we do NOT do: Patch `before_tool` to point at a script. That
  would silently no-op or, worse, write a malformed `HookRule` and
  break the user's config.

### 2. Codex is hook-only, not proxy-routed

- Source: [`internal/gateway/connector/codex.go`](../internal/gateway/connector/codex.go)
  near `buildCodexHooksTable` and `HookCapabilities`.
- Current contract: Codex `>=0.124.0` honors the stable hook table DefenseClaw
  writes to `~/.codex/config.toml`. DefenseClaw wires six lifecycle events;
  five are block-capable and `SessionStart` is context/telemetry only.
- Data path: Codex talks directly to its configured upstream model provider.
  DefenseClaw does **not** rewrite Codex through an LLM proxy. Inspection comes
  from lifecycle hooks, native OTel, and the agent-turn-complete notify bridge.
- HITL: Codex has no native ask response. `confirm` becomes an alert/system
  message with `raw_action` retained for audit; there is no TUI resume path.

---

## Implementation pointers

If you came here because something looks "missing" for ZeptoClaw or Codex
pre-tool gating, first identify which integration family you are inspecting:

- ZeptoClaw is proxy-backed; read its routing and response-scan path.
- Codex is hook-only; read `HookCapabilities`, `buildCodexHooksTable`, and the
  Codex response shaper.
- A host event not listed as block/ask-capable is telemetry or fallback, not a
  hidden approval queue.

Before adding code that "fixes" either case, check the checked public matrix at
`docs-site/data/capability-matrix.json`; connector tests now enforce parity for
all hook-backed rows.

---

## See also

- [`PR141-MATRIX-UPDATE.md`](PR141-MATRIX-UPDATE.md) — change history for
  every row, including which commit shipped each piece.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — overview of the proxy → connector
  → agent flow.
- Plan: `pr194_single_rollup` Phase C3.
