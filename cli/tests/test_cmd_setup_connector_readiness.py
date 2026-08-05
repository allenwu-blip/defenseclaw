from __future__ import annotations

import copy
import hashlib
import json
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest
from defenseclaw import agent_selection
from defenseclaw.commands import cmd_doctor, cmd_setup
from defenseclaw.connector_contracts import (
    connector_lock_contract_invariant,
    resolve_connector_contract,
)
from defenseclaw.cursor_contract import CursorRegistrationValidation
from defenseclaw.doctor_hooks import WindowsHookCheck
from defenseclaw.fail_mode import connector_registration_lock_state

TEN_CONNECTORS = (
    "codex",
    "claudecode",
    "cursor",
    "windsurf",
    "copilot",
    "antigravity",
    "opencode",
    "amp",
    "hermes",
    "omnigent",
)


def _guardrail(mode: str = "observe", fail_mode: str = "open") -> SimpleNamespace:
    return SimpleNamespace(
        connectors={},
        hook_fail_mode=fail_mode,
        effective_mode=lambda _name: mode,
        effective_hook_fail_mode=lambda _name: fail_mode,
        effective_hilt=lambda _name: SimpleNamespace(enabled=False),
    )


def _config(data_dir: Path) -> SimpleNamespace:
    return SimpleNamespace(
        data_dir=str(data_dir),
        deployment_mode="local",
        environment="test",
        guardrail=_guardrail(),
        gateway=SimpleNamespace(api_port=18970, resolved_token=lambda: "token"),
        connector_workspace_dir=lambda: "",
        plugin_dirs=lambda _name: [],
    )


def _entry(connector: str, root: Path) -> dict[str, object]:
    raw_version = "1.18.10" if connector == "opencode" else ""
    compatibility = resolve_connector_contract(connector, raw_version)
    assert compatibility.contract is not None
    config_path = root / f"{connector}-config.json"
    runtime_path = root / f"{connector}-runtime.bin"
    config_path.write_text("defenseclaw\n", encoding="utf-8")
    runtime_path.write_bytes(f"{connector}-runtime".encode())
    return {
        "connector": connector,
        "raw_agent_version": raw_version,
        "normalized_agent_version": compatibility.normalized_version,
        "contract_id": compatibility.contract.contract_id,
        "compatibility_status": compatibility.status,
        "hook_script_version": compatibility.contract.hook_script_version,
        "hook_fail_mode": "open",
        "hook_script_digests": {runtime_path.name: "sha256:" + hashlib.sha256(runtime_path.read_bytes()).hexdigest()},
        "locations": {
            "hook_config_paths": [str(config_path)],
            "hook_script_paths": [str(runtime_path)],
        },
    }


@pytest.mark.parametrize("connector", TEN_CONNECTORS)
def test_contract_lock_accepts_exact_ten(connector: str, tmp_path: Path) -> None:
    assert connector_lock_contract_invariant(connector, _entry(connector, tmp_path)) == ""


@pytest.mark.parametrize(
    ("field", "value", "invariant"),
    (
        ("contract_id", "wrong-contract", "contract"),
        ("hook_script_version", "v999", "version"),
        ("hook_fail_mode", "maybe", "fail-mode"),
    ),
)
def test_contract_lock_reports_exact_corrupt_invariant(
    field: str,
    value: str,
    invariant: str,
    tmp_path: Path,
) -> None:
    entry = _entry("amp", tmp_path)
    entry[field] = value
    assert connector_lock_contract_invariant("amp", entry) == invariant


def test_contract_lock_rejects_noncanonical_location(tmp_path: Path) -> None:
    entry = _entry("amp", tmp_path)
    locations = copy.deepcopy(entry["locations"])
    assert isinstance(locations, dict)
    locations["hook_config_paths"] = [str(tmp_path / "peer" / ".." / "amp-config.json")]
    entry["locations"] = locations
    assert connector_lock_contract_invariant("amp", entry) == "location"


def test_protected_executable_reports_identity_location_and_digest(monkeypatch, tmp_path: Path) -> None:
    executable = tmp_path / "amp.exe"
    executable.write_bytes(b"MZamp")
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    entry = {
        "agent_executable_source": "setup-selected",
        "agent_executable": str(executable),
        "agent_executable_sha256": digest,
    }
    monkeypatch.setattr(agent_selection, "is_setup_trusted_binary", lambda *_args: True)
    assert agent_selection.setup_agent_lock_executable_invariant(str(tmp_path), "amp", entry) == ""

    wrong_identity = dict(entry, agent_executable=str(tmp_path / "other.exe"))
    assert agent_selection.setup_agent_lock_executable_invariant(str(tmp_path), "amp", wrong_identity) == "executable"

    monkeypatch.setattr(agent_selection, "is_setup_trusted_binary", lambda *_args: False)
    assert agent_selection.setup_agent_lock_executable_invariant(str(tmp_path), "amp", entry) == "location"

    monkeypatch.setattr(agent_selection, "is_setup_trusted_binary", lambda *_args: True)
    stale_digest = dict(entry, agent_executable_sha256="0" * 64)
    assert agent_selection.setup_agent_lock_executable_invariant(str(tmp_path), "amp", stale_digest) == "digest"


def test_real_doctor_dispatch_exercises_exact_ten(monkeypatch, tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    config_paths: dict[str, str] = {}
    runtime_paths: dict[str, list[str]] = {}
    for connector in TEN_CONNECTORS:
        config = tmp_path / f"{connector}.json"
        runtime = tmp_path / f"{connector}.bin"
        config.write_text("defenseclaw", encoding="utf-8")
        runtime.write_bytes(b"runtime")
        config_paths[connector] = str(config)
        runtime_paths[connector] = [str(runtime)]

    omni_module = tmp_path / "defenseclaw_omnigent_policy.py"
    omni_pth = tmp_path / "defenseclaw_omnigent_policy.pth"
    omni_module.write_text("POLICY_REGISTRY = {'defenseclaw_policy': True}\n", encoding="utf-8")
    omni_pth.write_text(str(tmp_path), encoding="utf-8")
    runtime_paths["omnigent"] = [str(omni_module), str(omni_pth)]

    native_calls: list[str] = []

    def native_check(_cfg, connector: str, **_kwargs) -> WindowsHookCheck:
        native_calls.append(connector)
        return WindowsHookCheck("healthy", "registered", target=str(tmp_path / "defenseclaw-hook.exe"))

    monkeypatch.setattr(cmd_doctor, "_windows_native_hook_check", native_check)
    monkeypatch.setattr(cmd_doctor, "_hook_health_paths_from_lock", lambda _cfg, name: [config_paths[name]])
    monkeypatch.setattr(cmd_doctor, "_hook_runtime_paths_from_lock", lambda _cfg, name: runtime_paths[name])
    monkeypatch.setattr(cmd_doctor, "_file_references_marker", lambda *_args: True)
    monkeypatch.setattr(
        cmd_doctor,
        "validate_cursor_registration",
        lambda *_args, **_kwargs: CursorRegistrationValidation(
            True,
            "registered",
            runtime_path=runtime_paths["cursor"][0],
            entry_count=14,
        ),
    )
    monkeypatch.setattr(cmd_doctor, "_opencode_managed_plugin_drift", lambda *_args: "")
    monkeypatch.setattr(cmd_doctor, "_opencode_load_heartbeat_status", lambda _cfg: ("pass", "loaded"))
    monkeypatch.setattr(cmd_doctor, "_omnigent_managed_artifact_drift", lambda *_args: "")
    monkeypatch.setattr(
        cmd_doctor,
        "_omnigent_runtime_readiness",
        lambda _cfg: ("warn", "loaded policy generation is unverified pending reload/restart"),
    )
    monkeypatch.setattr(cmd_doctor, "hermes_profile_unsupported_reason", lambda *_args: "")
    monkeypatch.setattr(
        cmd_doctor,
        "copilot_settings_resolution",
        lambda *_args: SimpleNamespace(errors=(), disable_all_hooks=False),
    )

    expected_labels = set(cmd_doctor._SETUP_READINESS_PRIMARY_LABELS.values())
    observed_labels: set[str] = set()
    for connector in TEN_CONNECTORS:
        result = cmd_doctor._DoctorResult(passive=True, quiet=True)
        cmd_doctor._check_connector_hooks(cfg, connector, result)
        observed_labels.update(row["label"] for row in result.checks if row["label"] in expected_labels)

    assert observed_labels == expected_labels
    assert native_calls == ["codex", "claudecode", "windsurf", "copilot", "antigravity", "hermes"]


def _write_amp_runtime(tmp_path: Path) -> tuple[SimpleNamespace, dict[str, object]]:
    cfg = _config(tmp_path)
    entry = _entry("amp", tmp_path)
    config_path = Path(entry["locations"]["hook_config_paths"][0])
    config_path.write_text(
        '// DefenseClaw Amp policy bridge\nconst DC_FAIL_MODE: string = "open";\n/api/v1/amp/hook\n',
        encoding="utf-8",
    )
    lock = {"version": 2, "connectors": {"amp": entry}}
    (tmp_path / "hook_contract_lock.json").write_text(json.dumps(lock), encoding="utf-8")
    (tmp_path / "active_connector.json").write_text(
        json.dumps({"version": 3, "names": ["amp"], "inactive_names": []}),
        encoding="utf-8",
    )
    return cfg, entry


def _patch_amp_readiness_leaves(monkeypatch, cfg: SimpleNamespace, entry: dict[str, object]) -> None:
    config_path = entry["locations"]["hook_config_paths"][0]
    runtime_paths = entry["locations"]["hook_script_paths"]
    monkeypatch.setattr(cmd_setup, "load_config", lambda **_kwargs: cfg)
    monkeypatch.setattr(agent_selection, "setup_agent_lock_executable_invariant", lambda *_args: "")
    monkeypatch.setattr(cmd_doctor, "_hook_health_paths_from_lock", lambda *_args: [config_path])
    monkeypatch.setattr(cmd_doctor, "_hook_runtime_paths_from_lock", lambda *_args: runtime_paths)
    monkeypatch.setattr(cmd_doctor, "_opencode_managed_plugin_drift", lambda *_args: "")


def test_slow_real_dispatch_is_bounded_and_cannot_publish_late(monkeypatch, tmp_path: Path) -> None:
    cfg, entry = _write_amp_runtime(tmp_path)
    _patch_amp_readiness_leaves(monkeypatch, cfg, entry)
    started = threading.Event()
    release = threading.Event()

    def slow_marker(*_args) -> bool:
        started.set()
        release.wait(2.0)
        return True

    monkeypatch.setattr(cmd_doctor, "_file_references_marker", slow_marker)
    before = time.monotonic()
    result = cmd_setup._wait_for_connector_runtime(str(tmp_path), ["amp"], None, None, timeout=0.15)
    elapsed = time.monotonic() - before
    assert started.is_set(), result
    assert not result
    assert result.connector == "amp"
    assert result.invariant == "deadline"
    assert elapsed < 0.6
    release.set()
    time.sleep(0.05)
    assert not result


def test_gateway_unavailable_never_starts_connector_validation(monkeypatch, tmp_path: Path) -> None:
    cfg, entry = _write_amp_runtime(tmp_path)
    _patch_amp_readiness_leaves(monkeypatch, cfg, entry)
    started = False

    def marker(*_args) -> bool:
        nonlocal started
        started = True
        return True

    monkeypatch.setattr(cmd_doctor, "_file_references_marker", marker)
    monkeypatch.setattr(cmd_setup, "_read_gateway_health", lambda *_args, **_kwargs: None)
    result = cmd_setup._wait_for_connector_runtime(
        str(tmp_path),
        ["amp"],
        None,
        None,
        timeout=0.05,
        require_gateway_health=True,
    )
    assert not result
    assert result.invariant == "gateway-health"
    assert not started


def test_hermes_pending_reload_is_not_setup_ready(monkeypatch, tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    entry = _entry("hermes", tmp_path)
    (tmp_path / "hook_contract_lock.json").write_text(
        json.dumps({"version": 2, "connectors": {"hermes": entry}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_selection, "setup_agent_lock_executable_invariant", lambda *_args: "")
    monkeypatch.setattr(cmd_doctor, "hermes_profile_unsupported_reason", lambda *_args: "")
    monkeypatch.setattr(
        cmd_doctor,
        "_windows_native_hook_check",
        lambda *_args, **_kwargs: WindowsHookCheck(
            "pending-reload",
            "registration is on disk but live=false",
        ),
    )
    readiness = cmd_doctor.connector_setup_readiness(cfg, "hermes")
    assert not readiness
    assert readiness.connector == "hermes"
    assert readiness.invariant == "live-runtime"


def test_upstream_fail_open_remains_distinct_from_configured_mode(monkeypatch, tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    cfg.guardrail = _guardrail(fail_mode="closed")
    entry = _entry("hermes", tmp_path)
    entry["hook_fail_mode"] = "closed"
    (tmp_path / "hook_contract_lock.json").write_text(
        json.dumps({"version": 2, "connectors": {"hermes": entry}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_selection, "setup_agent_lock_executable_invariant", lambda *_args: "")
    monkeypatch.setattr(cmd_doctor, "hermes_profile_unsupported_reason", lambda *_args: "")
    monkeypatch.setattr(
        cmd_doctor,
        "_windows_native_hook_check",
        lambda *_args, **_kwargs: WindowsHookCheck("healthy", "registered"),
    )
    readiness = cmd_doctor.connector_setup_readiness(cfg, "hermes")
    assert readiness
    assert readiness.detail == "configured=closed; effective=open"


@pytest.mark.parametrize(("runtime_status", "ready"), (("warn", True), ("fail", False)))
def test_omnigent_native_degraded_is_accepted_but_failure_is_not(
    monkeypatch,
    tmp_path: Path,
    runtime_status: str,
    ready: bool,
) -> None:
    cfg = _config(tmp_path)
    entry = _entry("omnigent", tmp_path)
    config_path = Path(entry["locations"]["hook_config_paths"][0])
    config_path.write_text("defenseclaw_omnigent_policy defenseclaw_guardrail", encoding="utf-8")
    module_path = tmp_path / "defenseclaw_omnigent_policy.py"
    pth_path = tmp_path / "defenseclaw_omnigent_policy.pth"
    module_path.write_text("POLICY_REGISTRY = {'defenseclaw_policy': True}\n", encoding="utf-8")
    pth_path.write_text(str(tmp_path), encoding="utf-8")
    entry["locations"]["hook_script_paths"] = [str(module_path), str(pth_path)]
    entry["hook_script_digests"] = {
        path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() for path in (module_path, pth_path)
    }
    (tmp_path / "hook_contract_lock.json").write_text(
        json.dumps({"version": 2, "connectors": {"omnigent": entry}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(agent_selection, "setup_agent_lock_executable_invariant", lambda *_args: "")
    monkeypatch.setattr(cmd_doctor, "_file_references_marker", lambda *_args: True)
    monkeypatch.setattr(cmd_doctor, "_omnigent_managed_artifact_drift", lambda *_args: "")
    monkeypatch.setattr(
        cmd_doctor,
        "_omnigent_runtime_readiness",
        lambda _cfg: (runtime_status, "loaded policy generation remains unverified"),
    )
    readiness = cmd_doctor.connector_setup_readiness(cfg, "omnigent")
    assert bool(readiness) is ready
    if ready:
        assert readiness.detail == "configured=open; effective=open"


def test_copilot_stale_launcher_returns_executable_invariant(monkeypatch, tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    entry = _entry("copilot", tmp_path)
    (tmp_path / "hook_contract_lock.json").write_text(
        json.dumps({"version": 2, "connectors": {"copilot": entry}}),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        cmd_doctor,
        "copilot_settings_resolution",
        lambda *_args: SimpleNamespace(errors=(), disable_all_hooks=False),
    )
    monkeypatch.setattr(
        cmd_doctor,
        "_windows_native_hook_check",
        lambda *_args, **_kwargs: WindowsHookCheck("stale", "registered launcher executable is stale"),
    )
    readiness = cmd_doctor.connector_setup_readiness(cfg, "copilot")
    assert not readiness
    assert (readiness.connector, readiness.invariant) == ("copilot", "executable")


def test_readiness_lock_reports_digest_drift(monkeypatch, tmp_path: Path) -> None:
    cfg = _config(tmp_path)
    entry = _entry("amp", tmp_path)
    (tmp_path / "hook_contract_lock.json").write_text(
        json.dumps({"version": 2, "connectors": {"amp": entry}}),
        encoding="utf-8",
    )
    runtime_path = Path(entry["locations"]["hook_script_paths"][0])
    runtime_path.write_bytes(b"changed")
    monkeypatch.setattr(agent_selection, "setup_agent_lock_executable_invariant", lambda *_args: "")
    _mode, drift = connector_registration_lock_state(cfg, "amp")
    assert drift == "registration-digest-stale"


def test_snapshot_reports_one_peer_contract_drift(tmp_path: Path) -> None:
    lock = {"version": 2, "connectors": {name: _entry(name, tmp_path) for name in TEN_CONNECTORS}}
    lock["connectors"]["copilot"]["contract_id"] = "wrong"
    state = {"version": 3, "names": list(TEN_CONNECTORS), "inactive_names": []}
    result = cmd_setup._connector_runtime_snapshot_failure(
        state,
        2,
        lock,
        2,
        expected=set(TEN_CONNECTORS),
        previous_state_marker=1,
        previous_lock_marker=1,
    )
    assert not result
    assert (result.connector, result.invariant) == ("copilot", "contract")


def test_snapshot_accepts_exact_ten_roster(tmp_path: Path) -> None:
    lock = {"version": 2, "connectors": {name: _entry(name, tmp_path) for name in TEN_CONNECTORS}}
    state = {"version": 3, "names": list(TEN_CONNECTORS), "inactive_names": []}
    assert cmd_setup._connector_runtime_snapshot_ready(
        state,
        2,
        lock,
        2,
        expected=set(TEN_CONNECTORS),
        previous_state_marker=1,
        previous_lock_marker=1,
    )
