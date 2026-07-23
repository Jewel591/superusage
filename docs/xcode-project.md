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
