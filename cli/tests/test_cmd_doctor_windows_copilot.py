"""Focused native-Windows Copilot Doctor contract regressions."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from defenseclaw.commands.cmd_doctor import (
    _check_copilot_hooks,
    _check_hook_contract_lock,
    _DoctorResult,
)
from defenseclaw.doctor_hooks import (
    _COPILOT_REQUIRED_HOOKS,
    validate_windows_copilot_hook_registration,
)


def _powershell_command(runtime: Path) -> str:
    literal = str(runtime).replace("'", "''")
    return (
        "$ErrorActionPreference='Stop'; "
        "$env:NoDefaultCurrentDirectoryInExePath='1'; "
        r"$hookProcess=Microsoft.PowerShell.Management\Start-Process "
        f"-FilePath '{literal}' "
        "-ArgumentList @('hook','--connector','copilot') "
        "-NoNewWindow -Wait -PassThru; exit $hookProcess.ExitCode"
    )


def _fixture(tmp_path: Path) -> tuple[Path, Path, Path, str]:
    install = tmp_path / "DefenseClaw Install"
    data = tmp_path / ".defenseclaw"
    config = tmp_path / ".copilot" / "hooks" / "defenseclaw.json"
    install.mkdir()
    data.mkdir()
    config.parent.mkdir(parents=True)
    runtime = install / "defenseclaw-hook.exe"
    runtime.write_bytes(b"MZfixture")
    command = _powershell_command(runtime)
    hooks = {
        event: [{"type": "command", "powershell": command, "timeoutSec": 30}]
        for event in _COPILOT_REQUIRED_HOOKS
    }
    config.write_text(json.dumps({"version": 1, "hooks": hooks}), encoding="utf-8")
    lock = {
        "version": 2,
        "connectors": {
            "copilot": {
                "contract_id": "copilot-hooks-v1",
                "compatibility_status": "known",
                "raw_agent_version": "1.0.76",
                "normalized_agent_version": "1.0.76",
                "hook_script_version": "v6",
                "locations": {"hook_config_paths": [str(config)]},
            }
        },
    }
    (data / "hook_contract_lock.json").write_text(json.dumps(lock), encoding="utf-8")
    return install, data, config, command


def _validate(install: Path, data: Path, config: Path):
    return validate_windows_copilot_hook_registration(
        config_path=str(config),
        data_dir=str(data),
        install_root=str(install),
        search_path=str(install),
        pathext=".EXE;.CMD",
    )


def test_windows_copilot_doctor_accepts_complete_synchronous_contract(tmp_path: Path) -> None:
    install, data, config, _command = _fixture(tmp_path)

    check = _validate(install, data, config)

    assert check.state == "healthy", check.detail
    assert f"entries={len(_COPILOT_REQUIRED_HOOKS)}" in check.detail
    assert "contract=copilot-hooks-v1" in check.detail
    assert check.target.endswith("defenseclaw-hook.exe")


def test_windows_copilot_services_and_contract_rows_share_deep_validator(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install, data, config, _command = _fixture(tmp_path)
    cfg = SimpleNamespace(
        data_dir=str(data),
        claw=SimpleNamespace(workspace_dir=""),
        deployment_mode="single_user",
    )
    monkeypatch.setattr(
        "defenseclaw.inventory.agent_discovery._windows_acl_write_error",
        lambda _path: None,
    )

    services = _DoctorResult()
    _check_copilot_hooks(
        cfg,
        services,
        platform_name="nt",
        config_path=str(config),
        install_root=str(install),
        search_path=str(install),
        pathext=".EXE;.CMD",
    )
    assert services.checks[-1]["status"] == "pass", services.checks[-1]

    contract = _DoctorResult()
    _check_hook_contract_lock(
        cfg,
        "copilot",
        contract,
        platform_name="nt",
        config_path=str(config),
        install_root=str(install),
        search_path=str(install),
        pathext=".EXE;.CMD",
    )
    assert contract.checks[-1]["status"] == "pass", contract.checks[-1]
    assert "runtime_state" not in contract.checks[-1]["detail"]


@pytest.mark.parametrize(
    ("mutation", "expected"),
    [
        ("duplicated-call-operator", "duplicated call operator"),
        ("missing-event", "is missing"),
        ("wrong-timeout", "expected 30"),
        ("mixed-command-fields", "mixes the Windows powershell handler"),
        ("disabled", "disableAllHooks"),
        ("split-command", "inconsistent PowerShell commands"),
    ],
)
def test_windows_copilot_doctor_classifies_tamper(
    tmp_path: Path,
    mutation: str,
    expected: str,
) -> None:
    install, data, config, _command = _fixture(tmp_path)
    document = json.loads(config.read_text(encoding="utf-8"))
    if mutation == "duplicated-call-operator":
        document["hooks"]["preToolUse"][0]["powershell"] = (
            f"& & '{install / 'defenseclaw-hook.exe'}' hook --connector copilot"
        )
    elif mutation == "missing-event":
        document["hooks"].pop("permissionRequest")
    elif mutation == "wrong-timeout":
        document["hooks"]["agentStop"][0]["timeoutSec"] = 29
    elif mutation == "mixed-command-fields":
        document["hooks"]["preToolUse"][0]["bash"] = "foreign"
    elif mutation == "disabled":
        document["disableAllHooks"] = True
    elif mutation == "split-command":
        alternate = install / "alternate" / "defenseclaw-hook.exe"
        alternate.parent.mkdir()
        alternate.write_bytes(b"MZfixture")
        document["hooks"]["preToolUse"][0]["powershell"] = _powershell_command(alternate)
    config.write_text(json.dumps(document), encoding="utf-8")

    check = _validate(install, data, config)

    assert not check.healthy
    assert expected in check.detail
    assert "setup copilot --yes --restart" in check.detail
