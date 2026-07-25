# Xcode Project and Signing

`superUsage.xcodeproj` is the primary app-development surface. It provides one shared `superUsage`
scheme for Run, Profile, Analyze, and Archive.

## Project ownership

- `project.yml` is the source of truth.
- `superUsage.xcodeproj` is generated and committed so contributors can open it without installing a
  generator.
- Regenerate after target, dependency, capability, or build-setting changes:

  ```bash
  xcodegen generate --spec project.yml
  ```

- Do not hand-edit `project.pbxproj`; regeneration would overwrite those edits.

The project keeps the Swift package source layout. `UsageSync` and the `SuperUsage` module are built
as internal frameworks, while `Sources/SuperUsageApp` contains the thin macOS app entry point.
Because `SuperUsage` dynamically links Sparkle, the app target explicitly embeds and signs
`Sparkle.framework`. A post-build verification script fails the build if that runtime dependency is
missing or has an invalid signature.

## Dependency lockfiles (there are two)

The same three remote packages are pinned twice, because two build paths resolve them independently:

| File | Governs |
| --- | --- |
| `Package.resolved` | `swift build`, `swift test`, and the CI test job |
| `superUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Xcode locally and Xcode Cloud release builds |

Both are committed, and they must name the same version for every dependency they share — otherwise
the tests prove one version and users get another. Nothing syncs them automatically: Dependabot's
swift ecosystem only understands the SwiftPM manifest, so its bumps move the first file alone. The
`Lockfiles agree` CI job fails the PR when they drift apart, including when one has gone missing.

After any dependency change, resolve both, then `git add` both:

```bash
swift package resolve
xcodebuild -project superUsage.xcodeproj -scheme superUsage -resolvePackageDependencies
```

⚠️ If the Xcode lockfile **disappears** right after that resolve — `git status` showing a deletion of
a file you never touched — you've hit a state where `xcodebuild` removes the file moments after
writing it. It is not universal (a clean checkout resolves normally), but it reproduces persistently
in some working copies, and it is why this file has been committed as a deletion before. Never commit
that deletion: `git checkout -- <path>` puts it back. When the resolve genuinely changed it, copy it
out while the resolve is running and stage the copy directly, since the working-tree file won't
survive long enough for `git add`:

```bash
git hash-object -w /path/to/copy | xargs -I{} git update-index --add --cacheinfo 100644,{},\
  superUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

## Fixed Apple identity

- Team: Chengdu Weisen Quwan Technology Co., Ltd (`C554753V8P`)
- App bundle ID: `com.weisenjoytech.superusage`
- CloudKit container: `iCloud.com.weisenjoytech.usage.sync`
- Signing: automatic

The personal team `TP656CVH5C` must never be selected for this product.

The development version remains `0.0.0` build `0`. Do not choose a public release version without
product-owner approval.

## Verified build paths

An unsigned Debug build works for compile and bundle validation:

```bash
xcodebuild \
  -project superUsage.xcodeproj \
  -scheme superUsage \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

With the company account available in Xcode, Generic Mac Build and Product → Archive use the managed
company profile. The final app entitlement must contain:

- application identifier `C554753V8P.com.weisenjoytech.superusage`
- team identifier `C554753V8P`
- CloudKit service
- container `iCloud.com.weisenjoytech.usage.sync`

## Running on this Mac

Xcode Run needs a development profile containing this Mac's Provisioning UDID. If Xcode says the Mac
is not registered, the project and CloudKit configuration are still valid: an Account Holder or
Admin must register the Mac in the company team or grant device-management permission. Generic Mac
Build and Archive do not prove that the current Mac is included in the profile.

Do not work around that error by switching to the personal team.
