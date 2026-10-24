#!/usr/bin/env python3
"""The in-app Software Update's view of this checkout.

  status [--no-fetch] [--installed COMMIT]
                             JSON: where mine stands against upstream/main,
                             the Chromium engine both need, and what changed
                             since the installed build at COMMIT
  prepare --stage APP [--webkit]
                             merge upstream into mine, then build and stage
                             the app at APP (Personal/build-mac.sh --stage)
  install --staged APP       quit Crest, install the staged app, relaunch
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
UPSTREAM_REPOSITORY = "pauljoda/Crest"
ENGINE_SCRIPT = "Scripts/control-plane/chromium_engine.py"
ENGINE_INPUTS = (
    "CrestEngines/Chromium/source.lock.json",
    "CrestEngines/Chromium/host-inputs.json",
    "CrestEngines/Chromium/Patches",
    "CrestEngines/Chromium/Overlay",
    "CrestEngines/Chromium/Apple/CrestChromiumHost.h",
    "CrestContracts/include",
    "Scripts/control-plane/prepare-chromium.py",
    "Scripts/control-plane/apply-chromium-host.py",
    "Scripts/control-plane/configure-chromium.py",
    "Scripts/control-plane/build-chromium-baseline.py",
    ENGINE_SCRIPT,
)


def git(*arguments, check=True):
    result = subprocess.run(["git", *arguments], cwd=REPOSITORY, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def show(revision, path):
    result = subprocess.run(["git", "show", f"{revision}:{path}"], cwd=REPOSITORY, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def version_at(revision):
    text = show(revision, "Config/Version.xcconfig") or ""
    for line in text.splitlines():
        if line.startswith("MARKETING_VERSION = "):
            return line.split("= ", 1)[1].strip()
    return None


def chromium_version_at(revision):
    text = show(revision, "CrestEngines/Chromium/source.lock.json")
    if not text:
        return None
    try:
        return json.loads(text)["chromium"]["version"]
    except (KeyError, ValueError, TypeError):
        return None


def engine_tag_at(revision):
    """The engine release tag a revision needs, computed by that revision's
    own chromium_engine.py over an export of its engine inputs."""
    with tempfile.TemporaryDirectory(prefix="crest-engine-inputs-") as directory:
        archive = subprocess.run(
            ["git", "archive", revision, "--", *ENGINE_INPUTS],
            cwd=REPOSITORY, capture_output=True)
        if archive.returncode != 0:
            return None
        with tarfile.open(fileobj=__import__("io").BytesIO(archive.stdout)) as tar:
            tar.extractall(directory, filter="data")
        result = subprocess.run(
            [sys.executable, "-I", str(Path(directory) / ENGINE_SCRIPT), "tag", "--repo", directory],
            capture_output=True, text=True)
        return result.stdout.strip() or None


def engine_published(tag):
    if not tag:
        return None
    request = urllib.request.Request(
        f"https://api.github.com/repos/{UPSTREAM_REPOSITORY}/releases/tags/{tag}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "crest-personal-updater"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            return response.status == 200
    except urllib.error.HTTPError as error:
        return False if error.code == 404 else None
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def new_release_notes(old_revision, new_revision):
    old = show(old_revision, "Documentation/ReleaseNotes.json")
    new = show(new_revision, "Documentation/ReleaseNotes.json")
    if not new:
        return []
    try:
        old_entries = json.loads(old)["entries"] if old else {}
        new_entries = json.loads(new)["entries"]
    except (KeyError, ValueError, TypeError):
        return []
    notes = []
    for identifier, entry in new_entries.items():
        if identifier in old_entries or not isinstance(entry, dict):
            continue
        category = entry.get("category", "")
        if category == "internal":
            continue
        notes.append({"id": identifier, "category": category, "message": entry.get("message", "")})
    return notes


def known_commit(revision):
    """The full commit a revision names, or None when the repository does
    not have it, as after a rewrite of the branch it was built from."""
    if not revision:
        return None
    result = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{revision}^{{commit}}"],
                            cwd=REPOSITORY, capture_output=True, text=True)
    return result.stdout.strip() or None


def status(fetch, installed=None):
    report = {"checkout": str(REPOSITORY), "fetchError": None}
    report["branch"] = git("rev-parse", "--abbrev-ref", "HEAD")
    report["dirty"] = bool(git("status", "--porcelain"))
    if fetch:
        fetched = subprocess.run(["git", "fetch", "upstream", "--tags", "--prune", "--quiet"],
                                 cwd=REPOSITORY, capture_output=True, text=True, timeout=120)
        if fetched.returncode != 0:
            report["fetchError"] = fetched.stderr.strip().splitlines()[-1] if fetched.stderr.strip() else "git fetch failed"
    local = git("rev-parse", "HEAD")
    upstream = git("rev-parse", "upstream/main")
    report["local"] = {"commit": local, "version": version_at("HEAD")}
    report["upstream"] = {
        "commit": upstream,
        "version": version_at("upstream/main"),
        "behind": int(git("rev-list", "--count", "HEAD..upstream/main")),
        "ahead": int(git("rev-list", "--count", "upstream/main..HEAD")),
    }
    local_tag = engine_tag_at("HEAD")
    upstream_tag = engine_tag_at("upstream/main")
    report["engine"] = {
        "localTag": local_tag,
        "upstreamTag": upstream_tag,
        "localChromium": chromium_version_at("HEAD"),
        "upstreamChromium": chromium_version_at("upstream/main"),
        "upstreamPublished": True if upstream_tag == local_tag else engine_published(upstream_tag),
    }
    # The next build is HEAD with upstream merged in, so what it changes is
    # measured from the installed build: commits of your own since then as
    # much as upstream's.
    build = known_commit(installed)
    report["build"] = {
        "commit": build,
        "version": version_at(build) if build else None,
        "behind": int(git("rev-list", "--count", f"{build}..HEAD")) if build else 0,
    }
    base = build or "HEAD"
    notes = new_release_notes(base, "HEAD") if build else []
    seen = {note["id"] for note in notes}
    notes.extend(note for note in new_release_notes("HEAD", "upstream/main") if note["id"] not in seen)
    report["notes"] = notes
    subjects = git("log", "--format=%s", "HEAD", "upstream/main", "--not", base)
    report["commits"] = subjects.splitlines()[:40]
    return report


def run_streaming(command):
    """Runs a build step with its output flowing straight to ours, line by
    line. The step gets its own session, so cancelling this script (SIGTERM
    from the app) stops every process the step started, xcodebuild included."""
    import signal
    sys.stdout.flush()
    child = subprocess.Popen(command, cwd=REPOSITORY, stdout=sys.stdout, stderr=subprocess.STDOUT,
                             start_new_session=True)

    def stop(signum, frame):
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        raise SystemExit(130)

    previous = signal.signal(signal.SIGTERM, stop)
    try:
        return child.wait()
    finally:
        signal.signal(signal.SIGTERM, previous)


def prepare(stage, webkit):
    code = run_streaming(["/bin/zsh", str(REPOSITORY / "Personal/sync-upstream.sh")])
    if code != 0:
        return code
    build = ["/bin/zsh", str(REPOSITORY / "Personal/build-mac.sh"), "--stage", stage]
    if webkit:
        build.append("--webkit")
    return run_streaming(build)


def install(staged):
    return run_streaming(["/bin/zsh", str(REPOSITORY / "Personal/build-mac.sh"), "--install-staged", staged])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    status_parser = commands.add_parser("status")
    status_parser.add_argument("--no-fetch", action="store_true")
    status_parser.add_argument("--installed", help="the commit the running app was built from")
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--stage", required=True)
    prepare_parser.add_argument("--webkit", action="store_true")
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--staged", required=True)
    args = parser.parse_args()
    os.environ["PATH"] = ":".join(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
         str(Path.home() / ".dotnet"), os.environ.get("PATH", "")])
    if args.command == "status":
        try:
            print(json.dumps(status(fetch=not args.no_fetch, installed=args.installed)))
        except Exception as error:  # the app shows this line
            print(json.dumps({"error": str(error)}))
            return 1
        return 0
    if args.command == "prepare":
        code = prepare(args.stage, args.webkit)
    else:
        code = install(args.staged)
    # The app follows a log file when it runs this as a launchd job; this is
    # how it learns the step is over.
    print(f"::exit {code}", flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
