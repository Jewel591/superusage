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

The invariant checked is that both files pin the **same set** of dependencies at the same version and
revision. Comparing only the identities they happen to share would leave the same hole one size
smaller: a file that lost a pin outright — a half-finished resolve, a bad merge — agrees about
everything it still lists, while the dependency it dropped gets resolved freshly on that build path,
which is the exposure this check exists to prevent. `originHash` is excluded; it differs by design.

If a dependency ever legitimately belongs to one path only (a test-only SwiftPM dependency the app
target never links, say), this check has to be taught about it explicitly. That is the intent: making
someone say so beats silently accepting every one-sided pin.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFTPM = ROOT / "Package.resolved"
XCODE = ROOT / "superUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def pins(path: Path) -> dict[str, tuple[str, str]]:
    if not path.exists():
        # A missing file is a failure here, not a skip: an absent lockfile means Xcode Cloud resolves
        # release builds freshly, against whatever version happens to be newest that day. The Xcode one
        # has been committed as a deletion before — in some working copies it vanishes on its own after
        # `xcodebuild -resolvePackageDependencies` (see docs/xcode-project.md).
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


def describe(pin: tuple[str, str] | None) -> str:
    return f"{pin[0]} ({pin[1][:8]})" if pin else "not pinned"


def main() -> int:
    swiftpm, xcode = pins(SWIFTPM), pins(XCODE)
    disagreements = [
        (identity, swiftpm.get(identity), xcode.get(identity))
        for identity in sorted(swiftpm.keys() | xcode.keys())
        if swiftpm.get(identity) != xcode.get(identity)
    ]
    if not disagreements:
        print(f"{len(swiftpm)} dependencies pinned identically in both files")
        return 0

    print("The two Package.resolved files disagree:\n")
    for identity, swiftpm_pin, xcode_pin in disagreements:
        print(f"  {identity}")
        print(f"    Package.resolved                         {describe(swiftpm_pin)}")
        print(f"    superUsage.xcodeproj/…/Package.resolved  {describe(xcode_pin)}")
    print("\nTests and the shipped app would build against different dependency graphs.")
    if any(swiftpm_pin is None or xcode_pin is None for _, swiftpm_pin, xcode_pin in disagreements):
        print("A dependency missing from one lockfile is resolved freshly on that build path.")
    print(
        "To sync, resolve both:\n"
        "  swift package resolve\n"
        "  xcodebuild -project superUsage.xcodeproj -scheme superUsage -resolvePackageDependencies\n"
        "then commit both files. If the Xcode one disappears after that resolve instead of showing up "
        "modified, see docs/xcode-project.md."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
