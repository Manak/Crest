#!/usr/bin/env python3
"""Crest's plugin system: hooks patched into upstream code at build time, and
plugins compiled in beside them.

  status                 where each hook and plugin stands against the checkout
  apply [--dev]          patch the hooks in, lay out Plugins/.build, generate
                         the core contracts; --dev keeps a dirty tree and installs
                         a pre-commit guard
  revert                 restore every patched and generated file, remove the
                         build folder
  doctor [--scheme S] [--keep] [--configuration C]
                         apply, build, drop the plugins that do not compile, build
                         again; revert unless --keep
  enable ID / disable ID include or leave out a plugin at build time
  new ID --name N --summary S [--type T] [--core] [--patch-only]
                         scaffold a plugin
  capture                write the hook and plugin patches from the working tree
  bump ID [--minor|--major] --category C --note M
                         advance a plugin's version with a release note

The committed tree is upstream plus Plugins/ and Personal/. `apply` changes
upstream files only in the working tree; `revert` puts them back. Builds run
between the two.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "Plugins"
HOST = PLUGINS / "Host"
HOOKS = HOST / "Hooks"
BUILD = PLUGINS / ".build"
STATE_FILE = BUILD / "state.json"
MANIFEST_NAME = "CrestPlugins.json"
REGISTRY_NAME = "CrestPluginRegistry.generated.swift"
VERSION_FILE = ROOT / "Config/Version.xcconfig"
GENERATE_CONTRACTS = ROOT / "Scripts/control-plane/generate-contracts.sh"
GENERATED_FILES = (
    "CrestCore/src/CrestCore.Native/Generated/ContractCodec.g.cs",
    "CrestShared/Infrastructure/Core/Generated/CoreCodec.generated.swift",
    "CrestShared/Infrastructure/Core/Generated/CoreContracts.generated.swift",
    "CrestContracts/include/crest_contracts.h",
    "CrestContracts/include/crest_engine_contract.h",
)
ENGINE_CONTRACT = "CrestContracts/include/crest_engine_contract.h"
# Xcode may write strings a build extracted into the catalog, and `xcodegen
# generate` rewrites the committed project while hooks are applied.
RESTORED_WITH_HOOKS = ("CrestShared/Resources/Localizable.xcstrings", "Crest.xcodeproj")
CORE_SOURCES = ROOT / "CrestCore/src/CrestCore/PluginSources"
CORE_TESTS = ROOT / "CrestCore/tests/CrestCore.Tests/PluginSources"
# Hooks' own core sources go under this name, which no plugin id can take.
HOOK_CORE_FOLDER = "_hooks"
LOCAL_EXCLUDES = ("CrestCore/src/CrestCore/PluginSources/", "CrestCore/tests/CrestCore.Tests/PluginSources/")
OWN_PATHS = ("Plugins/", "Personal/")
ERROR_LINE = re.compile(r"^(?P<path>/[^:]+):(?P<line>\d+):(?P<column>\d+): error: (?P<message>.*)$")
PLUGIN_ID = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


class PluginError(Exception):
    """A problem the tool reports as its own, without a traceback."""


# MARK: - Git


def git(*arguments: str, check: bool = True, input: str | None = None) -> subprocess.CompletedProcess:
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True, input=input)
    if check and result.returncode != 0:
        raise PluginError(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result


def tracked(path: str) -> bool:
    return git("ls-files", "--error-unmatch", "--", path, check=False).returncode == 0


def crest_version() -> str:
    for line in VERSION_FILE.read_text().splitlines():
        if line.startswith("MARKETING_VERSION"):
            return line.split("=", 1)[1].strip()
    return "unknown"


def dirty_outside_own_paths() -> list[str]:
    """Upstream files changed in the working tree against the index. Staged
    changes are the developer's own and do not count."""
    paths = git("diff", "--name-only").stdout.splitlines()
    return [path for path in paths if not path.startswith(OWN_PATHS + RESTORED_WITH_HOOKS)]


# MARK: - Model


@dataclass
class PatchSet:
    """Patches to upstream files that stand or fall together: a hook, or a
    plugin's own patches."""

    id: str
    directory: Path
    files: list[str]

    def patch_path(self, file: str) -> Path:
        return self.directory / "patches" / (file.replace("/", "__") + ".patch")


@dataclass
class Hook(PatchSet):
    version: int = 1
    summary: str = ""
    required: bool = False

    @property
    def core(self) -> Path:
        """C# the hook adds to the core beside its patches: a partial of a
        type a patch made partial, or a record under CrestCore.Contracts."""
        return self.directory / "Core"

    @property
    def has_core(self) -> bool:
        return self.core.is_dir() and any(self.core.rglob("*.cs"))


@dataclass
class Plugin:
    id: str
    directory: Path
    included: bool
    manifest: dict

    @property
    def name(self) -> str:
        return self.manifest.get("name", self.id)

    @property
    def version(self) -> str:
        return self.manifest.get("version", "0.0.0")

    @property
    def hooks(self) -> dict[str, int]:
        return {key: int(value) for key, value in self.manifest.get("hooks", {}).items()}

    @property
    def type_name(self) -> str | None:
        return self.manifest.get("type")

    @property
    def platforms(self) -> list[str]:
        return self.manifest.get("platforms", ["macOS"])

    @property
    def sources(self) -> Path:
        return self.directory / "Sources"

    @property
    def core(self) -> Path:
        return self.directory / "Core"

    @property
    def tests(self) -> Path:
        return self.directory / "Tests"

    @property
    def core_tests(self) -> Path:
        return self.directory / "Tests" / "Core"

    @property
    def patches(self) -> PatchSet | None:
        files = self.manifest.get("files", [])
        if not files:
            return None
        return PatchSet(id=self.id, directory=self.directory, files=files)

    @property
    def tier(self) -> str:
        if self.core.is_dir() and any(self.core.rglob("*.cs")):
            return "core"
        if self.patches and not (self.sources.is_dir() and any(self.sources.rglob("*.swift"))):
            return "patch"
        return "hook"

    def bundled(self, available: bool, reason: str | None) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "summary": self.manifest.get("summary", ""),
            "tier": self.tier,
            "requiresRelaunch": bool(self.manifest.get("requiresRelaunch", False)),
            "enabledByDefault": bool(self.manifest.get("enabledByDefault", True)),
            "hooks": self.hooks,
            "available": available,
            "reason": reason,
        }


@dataclass
class Outcome:
    available: bool
    reason: str | None = None
    notes: list[str] = field(default_factory=list)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise PluginError(f"{path.relative_to(ROOT)}: {error}") from error


def load_host() -> dict:
    return read_json(HOST / "host.json")


def load_hooks(host: dict) -> list[Hook]:
    hooks = []
    for hook_id in host.get("hooks", []):
        directory = HOOKS / hook_id
        data = read_json(directory / "hook.json")
        if data.get("id") != hook_id:
            raise PluginError(f"{directory.relative_to(ROOT)}/hook.json names {data.get('id')!r}, not {hook_id!r}")
        hooks.append(Hook(
            id=hook_id, directory=directory, files=list(data.get("files", [])),
            version=int(data.get("version", 1)), summary=data.get("summary", ""),
            required=bool(data.get("required", False))))
    return hooks


def load_plugins() -> list[Plugin]:
    catalog = read_json(PLUGINS / "catalog.json")
    plugins = []
    for entry in catalog.get("plugins", []):
        plugin_id = entry["id"]
        if not PLUGIN_ID.match(plugin_id):
            raise PluginError(f"plugin id {plugin_id!r} must be lowercase kebab-case")
        directory = ROOT / entry.get("path", f"Plugins/{plugin_id}")
        manifest = read_json(directory / "plugin.json")
        if manifest.get("id") != plugin_id:
            raise PluginError(f"{directory.relative_to(ROOT)}/plugin.json names {manifest.get('id')!r}, not {plugin_id!r}")
        if not SEMVER.match(manifest.get("version", "")):
            raise PluginError(f"{plugin_id}: version must be strict X.Y.Z")
        plugins.append(Plugin(id=plugin_id, directory=directory, included=bool(entry.get("enabled", True)), manifest=manifest))
    return plugins


def check_file_ownership(hooks: list[Hook], plugins: list[Plugin]) -> None:
    owners: dict[str, str] = {}
    for unit in [*hooks, *(plugin.patches for plugin in plugins if plugin.patches)]:
        for file in unit.files:
            if file in owners:
                raise PluginError(f"{file} is patched by both {owners[file]} and {unit.id}; one unit owns a file")
            owners[file] = unit.id


def all_patched_files(hooks: list[Hook], plugins: list[Plugin]) -> list[str]:
    files: list[str] = []
    for unit in [*hooks, *(plugin.patches for plugin in plugins if plugin.patches)]:
        files.extend(unit.files)
    return files


# MARK: - Patching


def check_patch_set(unit: PatchSet, index: Path) -> Outcome:
    """Whether every patch of the unit would apply the way `apply_patch_set`
    applies it, cleanly or by a three-way merge, tried against a scratch
    `index` that holds the tree in question and is thrown away afterwards."""
    environment = dict(os.environ, GIT_INDEX_FILE=str(index))
    notes: list[str] = []
    for file in unit.files:
        patch = unit.patch_path(file)
        if not patch.is_file():
            return Outcome(False, f"no patch for {file}")
        clean = subprocess.run(["git", "apply", "--cached", "--check", str(patch)], cwd=ROOT, capture_output=True,
                               text=True, env=environment)
        if clean.returncode == 0:
            subprocess.run(["git", "apply", "--cached", str(patch)], cwd=ROOT, capture_output=True, env=environment)
            continue
        merged = subprocess.run(["git", "apply", "--cached", "--3way", str(patch)], cwd=ROOT, capture_output=True,
                                text=True, env=environment)
        if merged.returncode != 0:
            return Outcome(False, f"{file}: {summarize_apply_failure(merged.stderr)}")
        notes.append(f"{file} merges three-way")
    return Outcome(True, notes=notes)


def scratch_index(revision: str | None) -> Path:
    """A throwaway index: a copy of the real one, or `revision`'s tree for a
    revision that is not checked out, such as upstream's main."""
    BUILD.mkdir(parents=True, exist_ok=True)
    index = BUILD / ("scratch-index-" + (revision.replace("/", "-") if revision else "head"))
    if index.exists():
        index.unlink()
    if revision is None:
        real = Path(git("rev-parse", "--git-path", "index").stdout.strip())
        shutil.copy2(real if real.is_absolute() else ROOT / real, index)
        return index
    environment = dict(os.environ, GIT_INDEX_FILE=str(index))
    result = subprocess.run(["git", "read-tree", revision], cwd=ROOT, capture_output=True, text=True, env=environment)
    if result.returncode != 0:
        raise PluginError(f"cannot read {revision}: {result.stderr.strip()}")
    return index


def apply_patch_set(unit: PatchSet) -> Outcome:
    """Applies the unit to the working tree, falling back to a three-way merge
    for a file upstream moved around. A conflict restores the unit's files."""
    notes: list[str] = []
    applied: list[str] = []
    for file in unit.files:
        patch = unit.patch_path(file)
        if not patch.is_file():
            restore(applied)
            return Outcome(False, f"no patch for {file}")
        if git("apply", "--check", str(patch), check=False).returncode == 0:
            git("apply", str(patch))
        else:
            # `--3way` writes its result, merged or conflicted, to the index as
            # well as the working tree. The index entry goes back as it was, so
            # the working tree alone carries the hook and `restore` still finds
            # upstream's content there.
            entry = git("ls-files", "--stage", "--", file).stdout
            result = git("apply", "--3way", str(patch), check=False)
            if entry:
                git("update-index", "--index-info", input=entry)
            if result.returncode != 0:
                restore([*applied, file])
                return Outcome(False, f"{file}: {summarize_apply_failure(result.stderr)}")
            notes.append(f"{file} merged three-way")
        applied.append(file)
    return Outcome(True, notes=notes)


def summarize_apply_failure(stderr: str) -> str:
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    for line in lines:
        if "patch does not apply" in line or "does not exist" in line or "conflict" in line.lower():
            return line.removeprefix("error: ")
    return lines[-1].removeprefix("error: ") if lines else "patch does not apply"


def restore(files: list[str]) -> None:
    present = [file for file in files if tracked(file)]
    if not present:
        return
    # A three-way merge that conflicted leaves the path unmerged, which
    # `checkout` refuses; its index entry goes back to HEAD first.
    unmerged = sorted({line.split("\t", 1)[1] for line in git("ls-files", "--unmerged", "--", *present).stdout.splitlines()})
    if unmerged:
        git("reset", "-q", "--", *unmerged)
    git("checkout", "--", *present)


# MARK: - Build folder


def link(target: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.exists():
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    destination.symlink_to(os.path.relpath(target, destination.parent))


def ensure_local_excludes() -> None:
    # `--git-path` finds the common directory from a linked worktree too,
    # where `.git` is a file.
    exclude = Path(git("rev-parse", "--git-path", "info/exclude").stdout.strip())
    if not exclude.is_absolute():
        exclude = ROOT / exclude
    existing = exclude.read_text() if exclude.is_file() else ""
    missing = [line for line in LOCAL_EXCLUDES if line not in existing.splitlines()]
    if missing:
        exclude.parent.mkdir(parents=True, exist_ok=True)
        with exclude.open("a") as stream:
            if existing and not existing.endswith("\n"):
                stream.write("\n")
            stream.write("# Crest plugin sources copied in by Plugins/crest-plugins.py apply\n")
            stream.write("\n".join(missing) + "\n")


def write_build_folder(host: dict, hooks: list[Hook], hook_outcomes: dict[str, Outcome],
                       plugins: list[Plugin], plugin_outcomes: dict[str, Outcome]) -> None:
    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)
    link(HOST / "Sources/Shared", BUILD / "Shared")
    link(HOST / "Sources/Mac", BUILD / "Mac/Host")
    (BUILD / "Tests").mkdir()
    if (HOST / "Tests").is_dir():
        link(HOST / "Tests", BUILD / "Tests/Host")
    registry_types = []
    for plugin in plugins:
        outcome = plugin_outcomes[plugin.id]
        if not outcome.available:
            continue
        if plugin.sources.is_dir():
            link(plugin.sources, BUILD / "Mac" / plugin.id)
        if plugin.tests.is_dir() and any(plugin.tests.glob("*.swift")):
            link(plugin.tests, BUILD / "Tests" / plugin.id)
        if plugin.type_name:
            registry_types.append(plugin.type_name)
    registry = "\n".join([
        "// Generated by Plugins/crest-plugins.py apply. Do not edit.",
        "",
        "/// The plugin types this build carries, in catalog order.",
        "enum CrestPluginRegistry {",
        "    @MainActor static let plugins: [any CrestPlugin.Type] = [",
        *[f"        {name}.self," for name in registry_types],
        "    ]",
        "}",
        "",
    ])
    (BUILD / "Mac" / REGISTRY_NAME).write_text(registry)
    manifest = {
        "hostVersion": host.get("version", "0.0.0"),
        "hookCatalogVersion": int(host.get("hookCatalogVersion", 1)),
        "crestVersion": crest_version(),
        "hooks": [
            {"id": hook.id, "version": hook.version, "available": hook_outcomes[hook.id].available,
             "reason": hook_outcomes[hook.id].reason}
            for hook in hooks
        ],
        "plugins": [
            plugin.bundled(plugin_outcomes[plugin.id].available, plugin_outcomes[plugin.id].reason)
            for plugin in plugins if plugin.included
        ],
    }
    (BUILD / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2) + "\n")


def copy_core_sources(hooks: list[Hook], hook_outcomes: dict[str, Outcome], plugins: list[Plugin],
                      plugin_outcomes: dict[str, Outcome]) -> tuple[list[Hook], list[Plugin]]:
    """Copies the core sources of the applied hooks and the available core
    plugins into the core, and answers which hooks and plugins contributed."""
    for directory in (CORE_SOURCES, CORE_TESTS):
        if directory.exists():
            shutil.rmtree(directory)
    core_hooks = [h for h in hooks if hook_outcomes[h.id].available and h.has_core]
    core_plugins = [p for p in plugins if plugin_outcomes[p.id].available and p.tier == "core"]
    if not core_hooks and not core_plugins:
        return [], []
    ensure_local_excludes()
    for hook in core_hooks:
        shutil.copytree(hook.core, CORE_SOURCES / HOOK_CORE_FOLDER / hook.id)
    for plugin in core_plugins:
        shutil.copytree(plugin.core, CORE_SOURCES / plugin.id, ignore=shutil.ignore_patterns("Tests"))
        if plugin.core_tests.is_dir():
            shutil.copytree(plugin.core_tests, CORE_TESTS / plugin.id)
    return core_hooks, core_plugins


def generate_contracts() -> None:
    environment = dict(os.environ)
    environment["PATH"] = ":".join([str(Path.home() / ".dotnet"), environment.get("PATH", "")])
    result = subprocess.run(["/bin/zsh", str(GENERATE_CONTRACTS)], cwd=ROOT, capture_output=True, text=True,
                            env=environment)
    if result.returncode != 0:
        raise PluginError("contract generation failed:\n" + (result.stderr or result.stdout).strip()[-2000:])


def engine_contract_changed() -> bool:
    return git("diff", "--quiet", "--", ENGINE_CONTRACT, check=False).returncode != 0


# MARK: - State


def read_state() -> dict | None:
    if not STATE_FILE.is_file():
        return None
    try:
        return json.loads(STATE_FILE.read_text())
    except ValueError:
        return None


def write_state(state: dict) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


# MARK: - Availability


def plugin_availability(plugin: Plugin, hooks: list[Hook], hook_outcomes: dict[str, Outcome]) -> Outcome:
    if "macOS" not in plugin.platforms:
        return Outcome(False, "not for macOS")
    catalog = {hook.id: hook for hook in hooks}
    for hook_id, minimum in plugin.hooks.items():
        hook = catalog.get(hook_id)
        if hook is None:
            return Outcome(False, f"needs the {hook_id} hook, which this host does not have")
        if hook.version < minimum:
            return Outcome(False, f"needs {hook_id} version {minimum}; the host has {hook.version}")
        outcome = hook_outcomes[hook_id]
        if not outcome.available:
            return Outcome(False, f"needs the {hook_id} hook, which did not apply: {outcome.reason}")
    return Outcome(True)


# MARK: - Commands


def outlook(revision: str | None) -> dict:
    """Where every hook and plugin stands against the index, or against
    `revision`'s tree."""
    host = load_host()
    hooks = load_hooks(host)
    plugins = load_plugins()
    check_file_ownership(hooks, plugins)
    index = scratch_index(revision)
    try:
        hook_outcomes = {hook.id: check_patch_set(hook, index) for hook in hooks}
        plugin_outcomes: dict[str, Outcome] = {}
        for plugin in plugins:
            if not plugin.included:
                plugin_outcomes[plugin.id] = Outcome(False, "left out of the build (catalog)")
                continue
            outcome = plugin_availability(plugin, hooks, hook_outcomes)
            if outcome.available and plugin.patches:
                outcome = check_patch_set(plugin.patches, index)
                if not outcome.available:
                    outcome = Outcome(False, f"its own patch did not apply: {outcome.reason}")
            plugin_outcomes[plugin.id] = outcome
    finally:
        if index.exists():
            index.unlink()
    return {
        "revision": revision or "index",
        "crestVersion": crest_version() if revision is None else crest_version_at(revision),
        "host": {"version": host.get("version"), "hookCatalogVersion": host.get("hookCatalogVersion")},
        "hooks": [{"id": hook.id, "version": hook.version, "available": hook_outcomes[hook.id].available,
                   "reason": hook_outcomes[hook.id].reason, "notes": hook_outcomes[hook.id].notes} for hook in hooks],
        "plugins": [{"id": plugin.id, "version": plugin.version, "tier": plugin.tier, "included": plugin.included,
                     "available": plugin_outcomes[plugin.id].available, "reason": plugin_outcomes[plugin.id].reason,
                     "notes": plugin_outcomes[plugin.id].notes}
                    for plugin in plugins],
    }


def crest_version_at(revision: str) -> str:
    result = git("show", f"{revision}:Config/Version.xcconfig", check=False)
    for line in result.stdout.splitlines():
        if line.startswith("MARKETING_VERSION"):
            return line.split("=", 1)[1].strip()
    return "unknown"


def command_status(arguments: argparse.Namespace) -> int:
    report = outlook(arguments.revision)
    if arguments.json:
        print(json.dumps(report, indent=2))
        return 0
    target = f"{arguments.revision} (Crest {report['crestVersion']})" if arguments.revision else \
        f"the index (Crest {report['crestVersion']}, HEAD {git('rev-parse', '--short', 'HEAD').stdout.strip()})"
    print(f"Plugin host {report['host']['version']}, hook catalog {report['host']['hookCatalogVersion']}, "
          f"checked against {target}")
    if arguments.revision is None:
        print("Working tree: " + ("hooks applied" if read_state() else "clean, nothing applied"))
    print("\nHooks:")
    for hook in report["hooks"]:
        mark = "ok  " if hook["available"] else "FAIL"
        detail = hook["reason"] or "; ".join(hook["notes"])
        print(f"  {mark} {hook['id']} v{hook['version']}" + (f"  {detail}" if detail else ""))
    print("\nPlugins:")
    for plugin in report["plugins"]:
        mark = "ok  " if plugin["available"] else ("off " if not plugin["included"] else "FAIL")
        print(f"  {mark} {plugin['id']} {plugin['version']} ({plugin['tier']})"
              + (f"  {plugin['reason']}" if plugin["reason"] else ""))
    return 0


def perform_apply(dev: bool, excluded: dict[str, str] | None = None) -> dict:
    """Patches the hooks in and lays out the build folder. `excluded` names
    plugins the caller already knows do not compile, with the reason."""
    excluded = excluded or {}
    host = load_host()
    hooks = load_hooks(host)
    plugins = load_plugins()
    check_file_ownership(hooks, plugins)
    if read_state():
        perform_revert(quiet=True)
    dirty = dirty_outside_own_paths()
    if dirty and not dev:
        raise PluginError("the working tree has changes outside Plugins/ and Personal/; commit or stash them, "
                          "or pass --dev:\n  " + "\n  ".join(dirty))
    hook_outcomes: dict[str, Outcome] = {}
    for hook in hooks:
        outcome = apply_patch_set(hook)
        hook_outcomes[hook.id] = outcome
        if hook.required and not outcome.available:
            restore(all_patched_files(hooks, plugins))
            raise PluginError(f"the required {hook.id} hook does not apply to this Crest: {outcome.reason}")
    plugin_outcomes: dict[str, Outcome] = {}
    for plugin in plugins:
        if not plugin.included:
            plugin_outcomes[plugin.id] = Outcome(False, "left out of the build")
            continue
        if plugin.id in excluded:
            plugin_outcomes[plugin.id] = Outcome(False, excluded[plugin.id])
            continue
        outcome = plugin_availability(plugin, hooks, hook_outcomes)
        if outcome.available and plugin.patches:
            patched = apply_patch_set(plugin.patches)
            if not patched.available:
                outcome = Outcome(False, f"its own patch did not apply: {patched.reason}")
            else:
                outcome.notes.extend(patched.notes)
        plugin_outcomes[plugin.id] = outcome
    core_hooks, core_plugins = copy_core_sources(hooks, hook_outcomes, plugins, plugin_outcomes)
    if core_hooks or core_plugins:
        generate_contracts()
        if engine_contract_changed():
            # A hook's records are the host's own; a plugin's are left out.
            for plugin in core_plugins:
                plugin_outcomes[plugin.id] = Outcome(
                    False, "its core records change the engine contract, which the published Chromium engine fixes")
            copy_core_sources(hooks, hook_outcomes, plugins, plugin_outcomes)
            restore(list(GENERATED_FILES))
            if core_hooks:
                generate_contracts()
                if engine_contract_changed():
                    restore(list(GENERATED_FILES))
                    raise PluginError("a hook's core records change the engine contract, which the published "
                                      "Chromium engine fixes: " + ", ".join(hook.id for hook in core_hooks))
    write_build_folder(host, hooks, hook_outcomes, plugins, plugin_outcomes)
    state = {
        "appliedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "crestVersion": crest_version(),
        "head": git("rev-parse", "HEAD").stdout.strip(),
        "dev": dev,
        "hooks": {hook.id: {"available": o.available, "reason": o.reason, "notes": o.notes}
                  for hook, o in ((h, hook_outcomes[h.id]) for h in hooks)},
        "plugins": {plugin.id: {"available": o.available, "reason": o.reason, "notes": o.notes}
                    for plugin, o in ((p, plugin_outcomes[p.id]) for p in plugins)},
    }
    write_state(state)
    if dev:
        install_precommit_guard()
    return state


def print_state(state: dict) -> None:
    print("Hooks:")
    for hook_id, outcome in state["hooks"].items():
        mark = "ok  " if outcome["available"] else "FAIL"
        detail = outcome["reason"] or "; ".join(outcome.get("notes", []))
        print(f"  {mark} {hook_id}" + (f"  {detail}" if detail else ""))
    print("Plugins:")
    for plugin_id, outcome in state["plugins"].items():
        mark = "ok  " if outcome["available"] else "off "
        detail = outcome["reason"] or "; ".join(outcome.get("notes", []))
        print(f"  {mark} {plugin_id}" + (f"  {detail}" if detail else ""))


def command_apply(arguments: argparse.Namespace) -> int:
    state = perform_apply(dev=arguments.dev)
    print_state(state)
    return 0


def perform_revert(quiet: bool = False) -> None:
    host = load_host()
    hooks = load_hooks(host)
    plugins = load_plugins()
    files = all_patched_files(hooks, plugins) + list(GENERATED_FILES) + list(RESTORED_WITH_HOOKS)
    restore(sorted(set(files)))
    for directory in (CORE_SOURCES, CORE_TESTS, BUILD):
        if directory.exists():
            shutil.rmtree(directory)
    if not quiet:
        print("Restored the patched and generated files; removed Plugins/.build.")


def command_revert(arguments: argparse.Namespace) -> int:
    perform_revert()
    return 0


def install_precommit_guard() -> None:
    """Refuses a commit that stages a hooked or generated file while hooks are
    applied, so the applied state never lands in history."""
    hooks_directory = Path(git("rev-parse", "--git-path", "hooks").stdout.strip())
    if not hooks_directory.is_absolute():
        hooks_directory = ROOT / hooks_directory
    hooks_directory.mkdir(parents=True, exist_ok=True)
    guard = hooks_directory / "pre-commit"
    marker = "# crest-plugins guard"
    script = "\n".join([
        "#!/bin/sh",
        marker,
        'root="$(git rev-parse --show-toplevel)"',
        'if [ -f "$root/Plugins/.build/state.json" ]; then',
        '  python3 -I "$root/Plugins/crest-plugins.py" guard-commit || exit 1',
        "fi",
        "",
    ])
    if guard.exists() and marker not in guard.read_text():
        print(f"note: {guard} exists and is not the plugin guard; leaving it alone", file=sys.stderr)
        return
    guard.write_text(script)
    guard.chmod(0o755)


def command_guard_commit(arguments: argparse.Namespace) -> int:
    host = load_host()
    hooks = load_hooks(host)
    plugins = load_plugins()
    protected = set(all_patched_files(hooks, plugins)) | set(GENERATED_FILES) | set(RESTORED_WITH_HOOKS)
    staged = set(git("diff", "--cached", "--name-only").stdout.splitlines())
    offending = sorted(protected & staged)
    if offending:
        print("Hooks are applied; these staged files carry patched content. Run Plugins/crest-plugins.py revert "
              "(or capture, then revert) first:\n  " + "\n  ".join(offending), file=sys.stderr)
        return 1
    return 0


def command_doctor(arguments: argparse.Namespace) -> int:
    scheme = arguments.scheme
    derived = Path(arguments.derived_data).expanduser()
    excluded: dict[str, str] = {}
    state = None
    for attempt in range(1, 4):
        state = perform_apply(dev=True, excluded=excluded)
        print(f"== Build {attempt}: {scheme} ({arguments.configuration})")
        subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True, capture_output=True)
        command = [
            "xcodebuild", "build", "-project", "Crest.xcodeproj", "-scheme", scheme,
            "-configuration", arguments.configuration, "-destination", "generic/platform=macOS",
            "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "CURRENT_PROJECT_VERSION=1",
        ]
        environment = dict(os.environ)
        environment["PATH"] = ":".join([str(Path.home() / ".dotnet"), environment.get("PATH", "")])
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, env=environment)
        if result.returncode == 0:
            print("Build succeeded.")
            break
        errors = attribute_errors(result.stdout + result.stderr)
        unattributed = errors.pop(None, [])
        if not errors:
            print("The build failed outside any plugin:\n  " + "\n  ".join(unattributed[:20]), file=sys.stderr)
            finish_doctor(arguments, state, failed=True)
            return 1
        for plugin_id, messages in errors.items():
            excluded[plugin_id] = "did not compile: " + messages[0]
            print(f"-- {plugin_id} did not compile; leaving it out:\n     " + "\n     ".join(messages[:5]))
        if unattributed:
            print("   Other errors (may follow from the plugin's):\n     " + "\n     ".join(unattributed[:5]))
    else:
        print("The build still fails after three rounds.", file=sys.stderr)
        finish_doctor(arguments, state, failed=True)
        return 1
    if CORE_SOURCES.exists():
        print("== Core tests")
        environment = dict(os.environ)
        environment["PATH"] = ":".join([str(Path.home() / ".dotnet"), environment.get("PATH", "")])
        tests = subprocess.run(["dotnet", "test", "tests/CrestCore.Tests", "--nologo", "-v", "quiet"],
                               cwd=ROOT / "CrestCore", capture_output=True, text=True, env=environment)
        print(tests.stdout.strip()[-3000:])
        if tests.returncode != 0:
            print("Core tests failed.", file=sys.stderr)
            finish_doctor(arguments, state, failed=True)
            return 1
    finish_doctor(arguments, state, failed=False)
    return 0


def attribute_errors(output: str) -> dict[str | None, list[str]]:
    errors: dict[str | None, list[str]] = {}
    for line in output.splitlines():
        match = ERROR_LINE.match(line.strip())
        if not match:
            continue
        path = Path(match.group("path")).resolve()
        plugin_id = None
        try:
            relative = path.relative_to(ROOT)
            parts = relative.parts
            if parts[:3] == ("Plugins", ".build", "Mac") and len(parts) > 3 and parts[3] != "Host":
                plugin_id = parts[3]
            elif parts[:1] == ("Plugins",) and len(parts) > 1 and parts[1] not in (".build", "Host"):
                plugin_id = parts[1]
            elif parts[:4] == ("CrestCore", "src", "CrestCore", "PluginSources") and len(parts) > 4 \
                    and parts[4] != HOOK_CORE_FOLDER:
                plugin_id = parts[4]
        except ValueError:
            pass
        message = f"{match.group('path').replace(str(ROOT) + '/', '')}:{match.group('line')}: {match.group('message')}"
        errors.setdefault(plugin_id, []).append(message)
    return errors


def finish_doctor(arguments: argparse.Namespace, state: dict | None, failed: bool) -> None:
    if state:
        state["doctor"] = {"failed": failed, "scheme": arguments.scheme}
        write_state(state)
        print_state(state)
    if not arguments.keep:
        perform_revert()
        git("checkout", "--", "Crest.xcodeproj", check=False)


def command_enable(arguments: argparse.Namespace) -> int:
    return set_included(arguments.id, True)


def command_disable(arguments: argparse.Namespace) -> int:
    return set_included(arguments.id, False)


def set_included(plugin_id: str, included: bool) -> int:
    path = PLUGINS / "catalog.json"
    catalog = read_json(path)
    for entry in catalog.get("plugins", []):
        if entry["id"] == plugin_id:
            entry["enabled"] = included
            path.write_text(json.dumps(catalog, indent=2) + "\n")
            print(f"{plugin_id} is {'included in' if included else 'left out of'} the build.")
            return 0
    raise PluginError(f"no plugin {plugin_id!r} in Plugins/catalog.json")


def command_new(arguments: argparse.Namespace) -> int:
    plugin_id = arguments.id
    if not PLUGIN_ID.match(plugin_id):
        raise PluginError("the id must be lowercase kebab-case")
    directory = PLUGINS / plugin_id
    if directory.exists():
        raise PluginError(f"{directory.relative_to(ROOT)} exists")
    type_name = arguments.type or "".join(part.capitalize() for part in plugin_id.split("-")) + "Plugin"
    manifest = {
        "id": plugin_id,
        "name": arguments.name,
        "version": "1.0.0",
        "summary": arguments.summary,
        "platforms": ["macOS"],
        "hooks": {"bootstrap": 1},
        "requiresRelaunch": False,
        "enabledByDefault": True,
    }
    directory.mkdir(parents=True)
    if arguments.patch_only:
        manifest["files"] = []
        (directory / "patches").mkdir()
    else:
        manifest["type"] = type_name
        (directory / "Sources").mkdir()
        (directory / "Sources" / f"{type_name}.swift").write_text("\n".join([
            "import Foundation",
            "",
            f"/// {arguments.summary}",
            "@MainActor",
            f"final class {type_name}: CrestPlugin {{",
            "    // MARK: - Static Variables",
            "",
            f'    static let id = "{plugin_id}"',
            "",
            "    // MARK: - Initializers",
            "",
            "    init() {}",
            "",
            "    // MARK: - Actions - Lifecycle",
            "",
            "    func activate(_ context: CrestPluginContext) throws {",
            "    }",
            "}",
            "",
        ]))
    if arguments.core:
        (directory / "Core").mkdir()
        manifest["hooks"]["core.contracts"] = 1
    (directory / "plugin.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (directory / "ReleaseNotes.json").write_text(json.dumps({
        "schemaVersion": 2,
        "entries": {f"{plugin_id}-1-0-0": {"category": "new", "message": arguments.summary}},
    }, indent=2) + "\n")
    catalog_path = PLUGINS / "catalog.json"
    catalog = read_json(catalog_path)
    catalog.setdefault("plugins", []).append({"id": plugin_id, "enabled": True})
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"Scaffolded {directory.relative_to(ROOT)} and added it to the catalog.")
    return 0


def command_capture(arguments: argparse.Namespace) -> int:
    host = load_host()
    hooks = load_hooks(host)
    plugins = load_plugins()
    check_file_ownership(hooks, plugins)
    units: list[PatchSet] = [*hooks, *(plugin.patches for plugin in plugins if plugin.patches)]
    owned = set(all_patched_files(hooks, plugins))
    changed = set(git("diff", "--name-only").stdout.splitlines())
    ignored = owned | set(GENERATED_FILES) | set(RESTORED_WITH_HOOKS)
    unowned = sorted(path for path in changed - ignored if not path.startswith(OWN_PATHS + RESTORED_WITH_HOOKS))
    if unowned:
        raise PluginError("changed upstream files no hook or plugin owns; add each to a hook.json or plugin.json "
                          "files list first:\n  " + "\n  ".join(unowned))
    written = 0
    for unit in units:
        for file in unit.files:
            if not tracked(file):
                raise PluginError(f"{unit.id}: {file} is not an upstream file; new files belong in Plugins/")
            diff = git("diff", "--no-color", "--no-ext-diff", "--", file).stdout
            patch = unit.patch_path(file)
            if not diff:
                print(f"warning: {unit.id}: {file} has no change in the working tree; "
                      f"{'keeping' if patch.is_file() else 'no'} patch")
                continue
            patch.parent.mkdir(parents=True, exist_ok=True)
            patch.write_text(diff)
            written += 1
    print(f"Wrote {written} patch(es).")
    return 0


def command_bump(arguments: argparse.Namespace) -> int:
    plugins = {plugin.id: plugin for plugin in load_plugins()}
    plugin = plugins.get(arguments.id)
    if plugin is None:
        raise PluginError(f"no plugin {arguments.id!r}")
    major, minor, patch = (int(part) for part in plugin.version.split("."))
    if arguments.major:
        major, minor, patch = major + 1, 0, 0
    elif arguments.minor:
        minor, patch = minor + 1, 0
    else:
        patch += 1
    version = f"{major}.{minor}.{patch}"
    manifest_path = plugin.directory / "plugin.json"
    manifest = read_json(manifest_path)
    manifest["version"] = version
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    notes_path = plugin.directory / "ReleaseNotes.json"
    notes = read_json(notes_path) if notes_path.is_file() else {"schemaVersion": 2, "entries": {}}
    entry_id = arguments.entry_id or f"{plugin.id}-{version.replace('.', '-')}"
    if entry_id in notes["entries"]:
        raise PluginError(f"release note {entry_id!r} exists; pass --entry-id")
    notes["entries"][entry_id] = {"category": arguments.category, "message": arguments.note}
    notes_path.write_text(json.dumps(notes, indent=2, ensure_ascii=False) + "\n")
    print(f"{plugin.id} is now {version}; release note {entry_id} added.")
    return 0


# MARK: - Entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    status_parser = commands.add_parser("status")
    status_parser.add_argument("--revision", help="check against this revision's tree, such as upstream/main")
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(run=command_status)
    apply_parser = commands.add_parser("apply")
    apply_parser.add_argument("--dev", action="store_true", help="allow a dirty tree; install the commit guard")
    apply_parser.set_defaults(run=command_apply)
    commands.add_parser("revert").set_defaults(run=command_revert)
    doctor_parser = commands.add_parser("doctor")
    doctor_parser.add_argument("--scheme", default="CrestChromiumUIProduct")
    doctor_parser.add_argument("--configuration", default="Debug")
    doctor_parser.add_argument("--derived-data", default="~/Library/Developer/Xcode/DerivedData/Crest-Plugins")
    doctor_parser.add_argument("--keep", action="store_true", help="leave the hooks applied afterwards")
    doctor_parser.set_defaults(run=command_doctor)
    for name, run in (("enable", command_enable), ("disable", command_disable)):
        sub = commands.add_parser(name)
        sub.add_argument("id")
        sub.set_defaults(run=run)
    new_parser = commands.add_parser("new")
    new_parser.add_argument("id")
    new_parser.add_argument("--name", required=True)
    new_parser.add_argument("--summary", required=True)
    new_parser.add_argument("--type", help="the Swift type's name; derived from the id by default")
    new_parser.add_argument("--core", action="store_true", help="scaffold a Core/ folder for C# records")
    new_parser.add_argument("--patch-only", action="store_true", help="a plugin made of patches, with no Swift type")
    new_parser.set_defaults(run=command_new)
    commands.add_parser("capture").set_defaults(run=command_capture)
    bump_parser = commands.add_parser("bump")
    bump_parser.add_argument("id")
    bump_parser.add_argument("--minor", action="store_true")
    bump_parser.add_argument("--major", action="store_true")
    bump_parser.add_argument("--category", required=True, choices=("new", "improved", "fixed", "internal"))
    bump_parser.add_argument("--note", required=True)
    bump_parser.add_argument("--entry-id")
    bump_parser.set_defaults(run=command_bump)
    commands.add_parser("guard-commit").set_defaults(run=command_guard_commit)
    arguments = parser.parse_args()
    try:
        return arguments.run(arguments)
    except PluginError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
