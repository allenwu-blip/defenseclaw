# Cursor native Windows research gate

Last verified: 2026-07-30

Decision: eligible for a native Windows x64 DefenseClaw connector. Cursor
publishes both a native Windows Agent installation and native desktop
installers, and its command-hook interface provides synchronous pre-action
decisions over JSON stdin/stdout with an exit-code block signal. No WSL,
container, VM, Bash, Git Bash, Cygwin, or MSYS component is required by the
DefenseClaw path.

## Official sources and versions

- [Cursor CLI installation](https://cursor.com/docs/cli/installation) — the
  current Windows-native install command is
  `irm 'https://cursor.com/install?win32=true' | iex`. The same page documents
  `agent --version`, `agent`, and `agent update`. Its separate
  macOS/Linux/Windows-WSL command does not replace the native Windows method.
- [Cursor downloads](https://cursor.com/download) — on 2026-07-30 the page
  identified desktop release `3.13` and offered native Windows x64 and ARM64
  system and user installers. DefenseClaw's present Windows certification
  remains x64; an upstream ARM64 download is not a DefenseClaw ARM64
  certification.
- [Cursor 1.7 changelog](https://cursor.com/changelog/1-7) — dated
  2025-09-29. This release introduced beta hooks and states that Windows Agent
  commands use PowerShell.
- [Cursor CLI changelog](https://cursor.com/docs/cli/changelog) — the newest
  entry visible during verification was dated 2026-07-20. The changelog
  records native Windows reliability/update fixes and stdin hook payload
  support. The 2026-01-08 entry makes `agent` the primary CLI command while
  retaining `cursor-agent` as a compatibility alias.
- [Cursor hooks reference](https://cursor.com/docs/hooks) — current schema,
  event, I/O, configuration, failure, reload, and cloud-support contract.

Local observation is not used as upstream proof: the workstation used for this
review had Cursor desktop `3.9.16` at
`%LOCALAPPDATA%\Programs\cursor\resources\app\bin\cursor.cmd`; the separate
native `agent` command was not installed.

## Install and configuration contract

- Primary native CLI executable: `agent`; compatibility alias:
  `cursor-agent`. Desktop discovery also recognizes `cursor`.
- User hook file: `%USERPROFILE%\.cursor\hooks.json`
  (`~/.cursor/hooks.json` in Cursor's portable notation).
- Project hook file: `<project>\.cursor\hooks.json`.
- Windows enterprise hook file: `C:\ProgramData\Cursor\hooks.json`.
- Precedence: enterprise, team, project, user. Relative project commands run
  from the project root; relative user and enterprise commands run from their
  respective configuration directories.
- Hook configuration is schema version `1`. Per-command fields include
  `type: "command"`, `command`, `timeout` in **seconds**, and `failClosed`.
  Cursor automatically reloads configuration changes; if a change is not
  loaded, the documented recovery is to restart Cursor.

DefenseClaw writes the user hook file, uses a 30-second host timeout, and on
native Windows registers a PowerShell command that waits synchronously for the
native `defenseclaw-hook.exe` verdict. Setup/repair replaces only
DefenseClaw-owned entries and preserves foreign entries. Teardown restores the
captured file byte-for-byte when unchanged, otherwise removes only managed
entries. It then removes its owned Cursor scripts. It does not claim or depend
on an undocumented cached Cursor hook process/path.

## Synchronous I/O and enforcement

Cursor starts command hooks as spawned processes, writes one JSON document to
stdin, and reads one JSON document from stdout:

- exit `0`: hook succeeded and Cursor uses the JSON response;
- exit `2`: permission denied/block;
- other failures, crashes, timeouts, and invalid JSON: fail open by default;
- `failClosed: true`: those hook failures block instead.

DefenseClaw preserves the vendor default with `failClosed: false`. An explicit
action-mode closed failure setting writes `failClosed: true` and renders the
Windows adapter itself fail-closed, so an adapter/launcher failure returns a
deny object and exit `2`.

The current blocking/decision surfaces used by DefenseClaw are:

- `preToolUse`: `allow`/`deny`; the schema accepts `ask`, but Cursor currently
  does not enforce it;
- `beforeShellExecution` and `beforeMCPExecution`:
  `allow`/`deny`/`ask`;
- `beforeReadFile` and `beforeTabFileRead`: `allow`/`deny`;
- `beforeSubmitPrompt`: `continue: false` blocks prompt submission.

`stop` is not a permission gate; its only documented response is
`followup_message`. `sessionStart` and `sessionEnd` are fire-and-forget:
Cursor does not wait for their result or enforce a blocking response.

## Event inventory and limitations

The installed contract observes the current documented events:
`sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`,
`postToolUseFailure`, `subagentStart`, `subagentStop`,
`beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`,
`afterMCPExecution`, `beforeReadFile`, `afterFileEdit`,
`beforeTabFileRead`, `afterTabFileEdit`, `beforeSubmitPrompt`, `preCompact`,
`stop`, `afterAgentResponse`, `afterAgentThought`, and `workspaceOpen`.

Important limitations:

- Ask is enforceable only for shell and MCP pre-execution events.
- Post-action and fire-and-forget events provide observation, audit, and
  telemetry, not retroactive enforcement.
- User hooks are unavailable in Cursor cloud agents; cloud support is limited
  to command hooks and not every IDE event is available there. DefenseClaw's
  certification in this document is the local native Windows path.
- Cursor documents spawned hook processes and configuration reload. It does
  not document a persistent/cached hook-process lifecycle, so DefenseClaw does
  not invent one for repair or teardown.
