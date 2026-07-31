# Native macOS Antigravity Acceptance

Status date: 2026-07-31
Scope: Google Antigravity CLI (`agy`) on native macOS only. Gemini CLI,
proxy connectors, and other connector implementations are out of scope.

## Release and certification status

| Classification | Result |
| --- | --- |
| **OUTDATED** | The previous macOS platform claim said `supported` even though no macOS `last_validated_version` record existed. The prior “latest is 1.1.8” statement is also stale: Google's official macOS installer manifest now publishes 1.1.9. |
| **CURRENT / LIMITED** | DefenseClaw's reviewed macOS contract remains `>=1.1.8, <1.1.9`; Windows preserves `>=1.1.8` without a ceiling. The five-event 1.1.8 `antigravity-hooks-v2` contract and associated paths remain the reviewed implementation. The latest 1.1.9 release is correctly rejected as unknown on macOS pending a fresh contract review; its appearance in the manifest is not grounds to widen the ceiling. |
| **UNCERTIFIED** | macOS remains `preview`. `validated_versions.json` intentionally has an empty macOS `last_validated_version`, timestamp, and run URL. The persistent authenticated macOS connector-lab workflow is a source-build regression harness, not current-head packaged certification evidence, so no certification stamp was added. |

Primary sources:

- [Official macOS arm64 installer manifest](https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json)
- [Installation and authentication](https://antigravity.google/docs/cli/install)
- [Changelog](https://antigravity.google/changelog)
- [Hooks](https://antigravity.google/docs/hooks)
- [MCP](https://antigravity.google/docs/mcp)
- [Skills](https://antigravity.google/docs/skills)
- [Plugins](https://antigravity.google/docs/plugins)
- [CLI plugins and skills](https://antigravity.google/docs/cli/plugins)
- [CLI custom agents](https://antigravity.google/docs/cli/commands/agents)
- [Gemini CLI migration](https://antigravity.google/docs/cli/gcli-migration)

## Twelve-surface review

| # | Acceptance surface | macOS result |
| --- | --- | --- |
| 1 | Registry, discovery, version, platform | Implemented. `agy --version`; official `~/.local/bin/agy`; mandatory trusted-path admission before a passive Antigravity probe; macOS gate `>=1.1.8, <1.1.9`, while Windows remains unbounded above. Latest 1.1.9 is unsupported on macOS pending review; macOS is `preview`, not certified. |
| 2 | CLI, help, aliases | Implemented. `setup antigravity` remains canonical and `setup agy`/`init --connector agy` normalize to Antigravity, never Gemini CLI. |
| 3 | TUI, setup, status, repair | Implemented. Antigravity remains visible with a preview marker. Setup/status use the Antigravity connector identity. Doctor reports exact contract drift and points to scoped setup repair. |
| 4 | Narrow Setup custody and restoration | Implemented. Setup writes only five `defenseclaw-antigravity-*` keys in global `~/.gemini/config/hooks.json`. Exact pre-Setup bytes and mode are restored if unchanged; after operator drift, only DefenseClaw-owned keys are removed. `ANTIGRAVITY_CONFIG_DIR` is a DefenseClaw-internal, validated lifecycle binding for the selected profile, not a claimed upstream Antigravity override; Setup rejects unsafe path ancestry, overrides ambient state for the child operation, and restores it afterward. |
| 5 | Hook contract | Current. Exactly `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, and `Stop`; direct lists for invocation/stop and matcher groups for tool events. Only `PreToolUse` claims deny/ask. |
| 6 | Native process and provenance | Implemented. Native `agy` invokes the managed POSIX hook script synchronously. Passive discovery executes version probes only from trusted prefixes. No Gemini CLI or proxy executable is substituted. |
| 7 | Gateway, auth, lifecycle | Implemented. Connector-scoped token, Antigravity route, setup/teardown, loopback gateway, event-bound trusted header, and event-specific fail-open outputs are distinct from Gemini CLI. |
| 8 | Doctor, tamper, repair | Implemented. macOS Doctor passively validates all keys, shapes, timeouts, runtime path, and event bindings without executing config text; duplicate workspace registration is warned. |
| 9 | OTEL, audit, correlation | Implemented with limits. Telemetry is hook-derived logs/metrics/traces with connector identity and W3C context; Antigravity has no documented native OTLP exporter. Correlation uses `conversationId`, event-specific step/invocation fields, and never relabels `stepIdx` as a turn. |
| 10 | MCP, skills, plugins, rules, instructions, agents, assets | Implemented to documented boundaries. MCP and AgentSkills folder form are read/write; direct-markdown CLI skills are discovery-only; plugins install to the CLI staging root while shared/manual roots remain scanned; rules/instructions, standalone `agent.md` definitions, and plugin agents are discovery-only. Skill scripts/resources/assets are carried inside the skill directory. Runtime subagent processes are not managed. |
| 11 | Docs, matrix, limits | Updated. macOS preview and uncertified state, current release, five-event limits, shared-home custody, native-OTLP absence, and explicit N/A categories are recorded. |
| 12 | Deterministic, packaged, live, manual evidence | Deterministic contract/custody tests and a packaged contract matrix exist. The persistent macOS upgrade harness verifies official manifest SHA-512 artifacts while reusing Keychain auth and restoring exact config state, but it builds `main` source and does not retain the complete immutable package/manifest/custody record required for certification. Latest-version authenticated packaged evidence remains pending. |

## Explicit N/A categories

- Native model-traffic proxy, TLS interception, firewall ownership, and
  DefenseClaw-managed network sandbox: **N/A** (hook-only connector).
- Native Antigravity OTLP exporter: **N/A** (not documented).
- Gemini CLI settings, hooks, telemetry, credentials, process lifecycle, and
  migration ownership: **N/A** (separate connector despite shared
  `~/.gemini` ancestry).
- Workspace/plugin hook writes: **N/A** for DefenseClaw Setup; these are
  discovery-only to prevent duplicate hook execution.
- Standalone custom-agent writes: **N/A** for DefenseClaw management. Google
  documents global and workspace `agent.md` paths, which DefenseClaw discovers;
  Antigravity owns activation and runtime subagent/microagent processes.
- Workflow writes: **N/A** until Google documents a stable workflow file path.

## Evidence required to certify

Promoting macOS from preview requires one durable run from a reviewed,
immutable candidate corresponding to the current PR head
using the official latest stable macOS binary and a genuine authenticated
Keychain session. The evidence must retain the resolved version and manifest
digest, packaged DefenseClaw identity, all live probe results, setup config
hashes, audit/correlation artifacts, exact restoration proof, and immutable run
URL. A maintainer may then review that evidence and update
`last_validated_version`; the workflow must not update it automatically.
The existing main-branch source-build connector radar does not meet this bar.
