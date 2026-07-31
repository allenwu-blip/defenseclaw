# Copyright 2026 Cisco Systems, Inc. and its affiliates
#
# SPDX-License-Identifier: Apache-2.0

"""Security and compatibility tests for shared skill discovery."""

from __future__ import annotations

import os

import pytest
from defenseclaw.skill_discovery import discover_skill_directories


def test_codex_system_child_rejects_symlinked_marker(tmp_path) -> None:
    system_root = tmp_path / ".system"
    skill = system_root / "linked-marker"
    skill.mkdir(parents=True)
    real_marker = tmp_path / "outside.md"
    real_marker.write_text("# outside", encoding="utf-8")
    try:
        os.symlink(real_marker, skill / "SKILL.md")
    except OSError:
        pytest.skip("filesystem does not support symlinks")

    discovered = discover_skill_directories(os.fspath(tmp_path), connector="codex")

    assert "linked-marker" not in {entry.name for entry in discovered}


def test_codex_system_child_keeps_regular_marker(tmp_path) -> None:
    skill = tmp_path / ".system" / "legitimate"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("# legitimate", encoding="utf-8")

    discovered = discover_skill_directories(os.fspath(tmp_path), connector="codex")

    assert [(entry.name, entry.path, entry.bundled) for entry in discovered] == [
        ("legitimate", os.fspath(skill), True),
    ]


def test_claude_skills_directory_plugin_is_not_a_plain_skill(tmp_path) -> None:
    plain = tmp_path / "plain"
    plain.mkdir()
    (plain / "SKILL.md").write_text("# plain", encoding="utf-8")
    plugin = tmp_path / "storage-name"
    manifest = plugin / ".claude-plugin" / "plugin.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text('{"name":"semantic-name"}', encoding="utf-8")
    (plugin / "SKILL.md").write_text("# plugin skill", encoding="utf-8")

    discovered = discover_skill_directories(
        os.fspath(tmp_path),
        connector="claudecode",
    )

    assert [(entry.name, entry.path) for entry in discovered] == [
        ("plain", os.fspath(plain)),
    ]


def test_claude_legacy_command_markdown_is_discovered_as_a_skill(tmp_path) -> None:
    commands = tmp_path / ".claude" / "commands"
    commands.mkdir(parents=True)
    command = commands / "deploy.md"
    command.write_text("# Deploy\n", encoding="utf-8")
    (commands / "ignored.txt").write_text("ignored\n", encoding="utf-8")

    entries = discover_skill_directories(
        str(commands),
        connector="claudecode",
    )

    assert [(entry.name, entry.path) for entry in entries] == [
        ("deploy", str(command))
    ]


def test_claudecode_follows_and_deduplicates_skill_directory_symlinks(
    tmp_path,
) -> None:
    root = tmp_path / "skills"
    target = tmp_path / "shared-skill"
    root.mkdir()
    target.mkdir()
    (target / "SKILL.md").write_text("# Shared\n", encoding="utf-8")
    try:
        (root / "first").symlink_to(target, target_is_directory=True)
        (root / "second").symlink_to(target, target_is_directory=True)
    except OSError as exc:
        pytest.skip(f"directory symlinks unavailable: {exc}")

    discovered = discover_skill_directories(str(root), connector="claudecode")

    assert len(discovered) == 1
    assert discovered[0].path == str(target)
