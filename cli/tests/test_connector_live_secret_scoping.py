# Copyright 2026 Cisco Systems, Inc. and its affiliates
# SPDX-License-Identifier: Apache-2.0

"""Least-privilege contracts for live connector provider credentials."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "connector-live-e2e.yml"

PROVIDER_SECRETS = (
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AMP_API_KEY",
    "GOOGLE_API_KEY",
    "CURSOR_API_KEY",
    "COPILOT_GITHUB_TOKEN",
    "LLM_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AWS_BEARER_TOKEN_BEDROCK",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
)


def _jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]


def _step(job: dict, name: str) -> dict:
    return next(step for step in job["steps"] if step.get("name") == name)


def _secret_expression(secret: str, *connectors: str) -> str:
    comparisons = [f"matrix.connector == '{connector}'" for connector in connectors]
    condition = comparisons[0] if len(comparisons) == 1 else f"({' || '.join(comparisons)})"
    return f"${{{{ {condition} && secrets.{secret} || '' }}}}"


def _gated_secret_expression(secret: str, condition: str) -> str:
    return f"${{{{ {condition} && secrets.{secret} || '' }}}}"


def _provider_references(value: object) -> set[str]:
    rendered = str(value)
    return {secret for secret in PROVIDER_SECRETS if f"secrets.{secret}" in rendered}


def test_unix_live_secrets_are_connector_scoped_and_not_job_wide() -> None:
    live = _jobs()["live-matrix"]
    assert _provider_references(live.get("env", {})) == set()
    assert {
        "connector": "opencode",
        "os": "macos-latest",
        "dcos": "macos",
    } in live["strategy"]["matrix"]["include"]
    assert not any(
        cell.get("connector") == "opencode" and cell.get("dcos") != "macos"
        for cell in live["strategy"]["matrix"]["include"]
    )

    direct_openai = (
        "(matrix.connector == 'opencode' || "
        "(matrix.connector == 'codex' && env.DC_USE_AZURE != '1') || "
        "(matrix.connector == 'openhands' && env.DC_USE_BEDROCK != '1' && env.DC_USE_AZURE != '1'))"
    )
    direct_anthropic = "(matrix.connector == 'claudecode' && env.DC_USE_BEDROCK != '1')"
    direct_openhands = (
        "(matrix.connector == 'openhands' && env.DC_USE_BEDROCK != '1' && env.DC_USE_AZURE != '1')"
    )
    azure = (
        "((matrix.connector == 'codex' && env.DC_USE_AZURE == '1') || "
        "(matrix.connector == 'openhands' && env.DC_USE_BEDROCK != '1' && env.DC_USE_AZURE == '1'))"
    )
    bedrock = "((matrix.connector == 'claudecode' || matrix.connector == 'openhands') && env.DC_USE_BEDROCK == '1')"

    assert all(step.get("name") != "Seed DefenseClaw env" for step in live["steps"])

    driver = _step(live, "Live driver")
    assert driver["env"] == {
        "OPENAI_API_KEY": _gated_secret_expression("OPENAI_API_KEY", direct_openai),
        "ANTHROPIC_API_KEY": _gated_secret_expression("ANTHROPIC_API_KEY", direct_anthropic),
        "AMP_API_KEY": _secret_expression("AMP_API_KEY", "amp"),
        "CURSOR_API_KEY": _secret_expression("CURSOR_API_KEY", "cursor"),
        "COPILOT_GITHUB_TOKEN": _secret_expression("COPILOT_GITHUB_TOKEN", "copilot"),
        "LLM_API_KEY": _gated_secret_expression("LLM_API_KEY", direct_openhands),
        "AZURE_OPENAI_API_KEY": _gated_secret_expression("AZURE_OPENAI_API_KEY", azure),
        "AWS_BEARER_TOKEN_BEDROCK": _gated_secret_expression("AWS_BEARER_TOKEN_BEDROCK", bedrock),
        "AWS_ACCESS_KEY_ID": _gated_secret_expression("AWS_ACCESS_KEY_ID", bedrock),
        "AWS_SECRET_ACCESS_KEY": _gated_secret_expression("AWS_SECRET_ACCESS_KEY", bedrock),
        "AWS_SESSION_TOKEN": _gated_secret_expression("AWS_SESSION_TOKEN", bedrock),
    }

    cursor = _step(live, "Validate Cursor headless hooks")
    assert cursor["env"] == {"CURSOR_API_KEY": _secret_expression("CURSOR_API_KEY", "cursor")}
    assert _step(live, "Initialize DefenseClaw without provider credentials").get("env") is None

    allowed = {"Validate Cursor headless hooks", "Live driver"}
    for step in live["steps"]:
        if step.get("name") not in allowed:
            assert _provider_references(step) == set(), step.get("name", step.get("uses"))


def test_live_installers_do_not_receive_or_persist_provider_credentials_early() -> None:
    common = (ROOT / "scripts/live-connector-e2e/lib/common.sh").read_text(encoding="utf-8")
    helper = common.split("dc_without_provider_credentials() {", 1)[1].split("\n}", 1)[0]
    for secret in PROVIDER_SECRETS:
        assert f"-u {secret}" in helper
    assert 'raw="$(dc_without_provider_credentials "$@"' in common

    drivers = ROOT / "scripts" / "live-connector-e2e" / "drivers"
    codex = (drivers / "codex.sh").read_text(encoding="utf-8")
    assert "npm install -g --ignore-scripts" in codex
    assert codex.index("dc_without_provider_credentials npm install") < codex.index(
        "dc_write_env_key OPENAI_API_KEY"
    )
    assert "codex --version" not in codex

    opencode = (drivers / "opencode.sh").read_text(encoding="utf-8")
    assert "dc_without_provider_credentials npm install" in opencode
    assert opencode.index("dc_without_provider_credentials npm install") < opencode.index(
        "dc_write_env_key OPENAI_API_KEY"
    )

    openhands = (drivers / "openhands.sh").read_text(encoding="utf-8")
    assert "dc_without_provider_credentials uv tool install" in openhands
    assert openhands.index("dc_without_provider_credentials uv tool install") < openhands.index(
        "dc_write_env_key LLM_API_KEY"
    )
    assert "dc_write_env_key AWS_" not in openhands
    assert "dc_write_env_key AZURE_OPENAI_API_KEY" not in openhands

    claude = (drivers / "claudecode.sh").read_text(encoding="utf-8")
    assert claude.index('DC_E2E_AGENT_VERSION="${version}"') < claude.index(
        "dc_write_env_key ANTHROPIC_API_KEY"
    )
    assert "dc_write_env_key AWS_" not in claude


def test_windows_live_provider_secrets_are_harness_and_connector_scoped() -> None:
    windows = _jobs()["windows-live"]
    assert _provider_references(windows.get("env", {})) == set()

    harness = _step(windows, "Native Windows live harness")
    assert harness["env"] == {
        "OPENAI_API_KEY": _secret_expression("OPENAI_API_KEY", "codex", "opencode"),
        "ANTHROPIC_API_KEY": _secret_expression("ANTHROPIC_API_KEY", "claudecode"),
        "AMP_API_KEY": _secret_expression("AMP_API_KEY", "amp"),
        "CURSOR_API_KEY": _secret_expression("CURSOR_API_KEY", "cursor"),
    }

    for step in windows["steps"]:
        if step.get("name") != "Native Windows live harness":
            assert _provider_references(step) == set(), step.get("name", step.get("uses"))
