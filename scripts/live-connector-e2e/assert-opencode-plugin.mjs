// Copyright 2026 Cisco Systems, Inc. and its affiliates
// SPDX-License-Identifier: Apache-2.0

import { copyFile, rm } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const [pluginPath, scratchPath, expected, command] = process.argv.slice(2);
if (!pluginPath || !scratchPath || !["allow", "block"].includes(expected) || !command) {
  throw new Error(
    "usage: node assert-opencode-plugin.mjs <plugin.js> <scratch.mjs> <allow|block> <command>",
  );
}

await copyFile(pluginPath, scratchPath);
try {
  const module = await import(`${pathToFileURL(scratchPath).href}?v=${Date.now()}`);
  if (typeof module.DefenseClaw !== "function") {
    throw new Error("installed OpenCode plugin does not export DefenseClaw");
  }
  const hooks = await module.DefenseClaw({
    directory: process.cwd(),
    worktree: process.cwd(),
  });
  if (
    typeof hooks["tool.execute.before"] !== "function" ||
    typeof hooks["tool.execute.after"] !== "function" ||
    typeof hooks.event !== "function"
  ) {
    throw new Error("installed OpenCode plugin is missing required hook functions");
  }

  let blocked = false;
  try {
    await hooks["tool.execute.before"](
      {
        tool: "bash",
        sessionID: "defenseclaw-windows-contract",
        callID: "defenseclaw-windows-contract-call",
      },
      { args: { command } },
    );
  } catch (error) {
    blocked = true;
    if (!(error instanceof Error) || !error.message) {
      throw new Error("OpenCode block path did not throw an Error with a reason");
    }
  }
  if ((expected === "block") !== blocked) {
    throw new Error(`OpenCode plugin verdict mismatch: expected=${expected} blocked=${blocked}`);
  }

  // This hook is intentionally observe-only. Awaiting its returned promise
  // proves the handler itself completes without turning telemetry failure into
  // a tool failure; the plugin does not await its internal POST.
  await hooks["tool.execute.after"](
    {
      tool: "bash",
      sessionID: "defenseclaw-windows-contract",
      callID: "defenseclaw-windows-contract-call",
    },
    { args: { command } },
  );
} finally {
  await rm(scratchPath, { force: true });
}
