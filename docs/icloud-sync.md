# CloudKit Sync

**Sync to Apple Devices** is off by default. When enabled, superUsage publishes a versioned,
normalized usage snapshot from the Mac to the user's private CloudKit database. Cursornow on iPhone,
iPad, and Apple Watch reads the mirrored Core Data replica and never writes usage data.

The payload contains provider names, normalized metrics, refresh times, a source-device identifier,
and a monotonic revision. It does not contain credentials, raw logs, or raw provider responses.

CloudKit delivery is eventually consistent. A mobile device may take several minutes to receive a new
snapshot, especially while offline or under system background limits. The clients should always show
the snapshot generation time and retain the last valid local replica.

## Development and release setup

The planned resources belong to Chengdu Weisen Quwan Technology Co., Ltd:

- Team ID: `C554753V8P`
- macOS bundle ID: `com.weisenjoytech.superusage`
- existing mobile bundle ID: `com.weisenjoytech.Cursornow`
- shared CloudKit container: `iCloud.com.weisenjoytech.usage.sync`

These identifiers are present in source and signing templates but still need to be registered and
assigned in the Apple developer portal. Do not use the personal team `TP656CVH5C` or the old MVP
container `iCloud.com.linliao.openusage.sync`.

For development, create a `MAC_APP_DEVELOPMENT` profile that includes the Mac and explicitly selects
the CloudKit `Development` environment. For direct distribution, create a `MAC_APP_DIRECT` profile
after the container and production schema are ready. The build script selects the newest matching
installed development profile:

```bash
./script/build_and_run.sh
```

Set `ICLOUD_PROVISIONING_PROFILE=/path/to/profile.mobileprovision` only to override automatic
selection. An explicit missing path fails the build instead of silently producing an app without
CloudKit access.

The release workflow reads the base64-encoded direct-distribution profile from the repository Actions
secret `APPLE_DEVELOPER_ID_ICLOUD_PROFILE`. Keep provisioning profiles and signing `.p12` files in a
password manager, never in the repository.

## Verification order

1. Confirm the signed app's team, application identifier, container identifier, and CloudKit
   environment with `codesign -d --entitlements :-`.
2. Run the signing bootstrap probe under the same profile.
3. Initialize the development schema once with
   `SUPERUSAGE_INITIALIZE_CLOUDKIT_SCHEMA=1`.
4. Publish from superUsage on the Mac.
5. Read from a Cursornow development build on a real iPhone signed with the same team and container.
6. Inspect CloudKit Console development logs and data only after both binaries have verified
   entitlements.

`CKErrorDomain` code 15 usually means the signed identity, provisioning profile, container assignment,
or selected environment does not match. Treat it as an entitlement/configuration problem first, not
as evidence that the snapshot code or CloudKit service is unavailable.

## Legacy iCloud Documents code

The imported codebase includes an older **Sync Across Macs** implementation that exchanges JSON files
through iCloud Documents and combines machine-local history. It is currently dormant and is not wired
into the app composition root because the product direction uses CloudKit snapshots. It can be
evaluated or removed in a focused follow-up after compatibility requirements are clear.
