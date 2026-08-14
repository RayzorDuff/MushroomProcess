#!/usr/bin/env python3
"""Prepare or verify a MushroomProcess release without committing or tagging."""
from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$")


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True)


def verify(version: str) -> None:
    failures = []
    if not SEMVER.fullmatch(version):
        failures.append(f"VERSION is not semantic versioning: {version!r}")
    changelog = (ROOT / "doc/CHANGELOG.md").read_text(encoding="utf-8")
    if not re.search(rf"^## \[?v?{re.escape(version)}\]?\s+-\s+\d{{4}}-\d{{2}}-\d{{2}}$", changelog, re.M):
        failures.append("doc/CHANGELOG.md has no dated heading for VERSION")
    notes = ROOT / f"releases/v{version}/RELEASE_NOTES.md"
    if not notes.exists():
        failures.append(f"missing {notes.relative_to(ROOT)}")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    if f"Current version: **{version}**." not in readme:
        failures.append("README.md version does not match VERSION")
    if failures:
        raise SystemExit("Release check failed:\n- " + "\n- ".join(failures))


def prepare(version: str, release_date: str) -> None:
    if not SEMVER.fullmatch(version):
        raise SystemExit(f"Invalid semantic version: {version}")
    dt.date.fromisoformat(release_date)
    if git("status", "--porcelain").stdout.strip():
        raise SystemExit("Working tree must be clean before preparing a release.")
    old = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    (ROOT / "VERSION").write_text(version + "\n", encoding="utf-8")
    readme_path = ROOT / "README.md"
    readme = readme_path.read_text(encoding="utf-8")
    readme = re.sub(r"^Current version: \*\*[^*]+\*\*\.$", f"Current version: **{version}**.", readme, count=1, flags=re.M)
    readme_path.write_text(readme, encoding="utf-8")
    notes = ROOT / f"releases/v{version}/RELEASE_NOTES.md"
    notes.parent.mkdir(parents=True, exist_ok=True)
    if not notes.exists():
        notes.write_text(f"# MushroomProcess v{version}\n\nRelease date: {release_date}\n\n## Summary\n\nTODO\n", encoding="utf-8")
    print(f"Prepared MushroomProcess {old} -> {version}. Update the changelog and release notes, then run make release-check.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version")
    parser.add_argument("--release-date", default=dt.date.today().isoformat())
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    current = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if args.check:
        verify(current)
    elif args.version:
        prepare(args.version, args.release_date)
    else:
        parser.error("use --check or --version")


if __name__ == "__main__":
    main()
