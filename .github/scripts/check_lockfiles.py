#!/usr/bin/env python3
"""Fail when the two committed `Package.resolved` files disagree about a dependency.

superUsage has two of them, for two build paths that resolve independently:

  * `Package.resolved` — SwiftPM, used by `swift build` and `swift test`.
  * `superUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — the Xcode
    project's own package graph (project.yml declares the same three remote packages), used by Xcode
    locally and by Xcode Cloud when it builds a release.

Nothing keeps them in step. Dependabot's swift ecosystem reads the SwiftPM manifest and updates that
file alone, so a version bump lands in tests while the shipped app keeps linking the old one — the
state this repo was actually in (SwiftPM 3.64.5 / Xcode 3.67.0 / neither what a fresh resolve picked).
Nothing fails when that happens, which is why it went unnoticed; this check is what makes it fail.

Only shared identities are compared, and only version + revision: each file may legitimately list
dependencies the other doesn't, and `originHash` differs by design.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFTPM = ROOT / "Package.resolved"
XCODE = ROOT / "superUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def pins(path: Path) -> dict[str, tuple[str, str]]:
    if not path.exists():
        # Locally, `xcodebuild -resolvePackageDependencies` writes the Xcode file and then removes it
        # again, so it can vanish from a working tree and be committed as a deletion by accident. A
        # missing file is a failure here, not a skip: an absent lockfile means Xcode Cloud resolves
        # release builds freshly, against whatever version happens to be newest that day.
        sys.exit(f"missing lockfile: {path.relative_to(ROOT)}")
    data = json.loads(path.read_text())
    resolved = {
        pin["identity"]: (pin["state"].get("version", ""), pin["state"].get("revision", ""))
        for pin in data.get("pins", [])
    }
    if not resolved:
        # A pinless file is valid JSON and would otherwise pass, because comparing shared identities of
        # an empty set finds nothing to disagree about. It pins nothing, which is the same exposure as
        # having no file at all: this project always has dependencies to pin.
        sys.exit(f"lockfile pins nothing: {path.relative_to(ROOT)}")
    return resolved


def main() -> int:
    swiftpm, xcode = pins(SWIFTPM), pins(XCODE)
    conflicts = [
        (identity, swiftpm[identity], xcode[identity])
        for identity in sorted(swiftpm.keys() & xcode.keys())
        if swiftpm[identity] != xcode[identity]
    ]
    if not conflicts:
        print(f"{len(swiftpm.keys() & xcode.keys())} shared dependencies pinned identically")
        return 0

    print("The two Package.resolved files disagree:\n")
    for identity, (spm_version, spm_revision), (xc_version, xc_revision) in conflicts:
        print(f"  {identity}")
        print(f"    Package.resolved                  {spm_version} ({spm_revision[:8]})")
        print(f"    superUsage.xcodeproj/…/Package.resolved  {xc_version} ({xc_revision[:8]})")
    print(
        "\nTests and the shipped app would build against different versions. To sync, resolve both:\n"
        "  swift package resolve\n"
        "  xcodebuild -project superUsage.xcodeproj -scheme superUsage -resolvePackageDependencies\n"
        "then commit both files (see docs/xcode-project.md — the Xcode one needs care, xcodebuild "
        "deletes it right after writing it)."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
