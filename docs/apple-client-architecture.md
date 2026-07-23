# Apple Client Architecture

superUsage has one data authority: the Mac app. It reads local credentials and logs, calls providers,
prices usage, and publishes a normalized snapshot. Cursornow on iPhone, iPad, and Apple Watch only
reads and displays that snapshot.

```text
Provider APIs + local logs
            |
            v
       superUsage Mac  ---- private CloudKit database ----> Cursornow
       (only writer)       Core Data local replicas          iPhone / iPad
                                                               |
                                                               v
                                                        Apple Watch / Widget
```

## Repository boundary

- [`Jewel591/superusage`](https://github.com/Jewel591/superusage) is the public macOS repository. It
  owns the Mac writer and the reusable `UsageSync` Swift package product.
- `Jewel591/Cursornow` is the private Apple-client repository. It owns the existing App Store identity
  and the iPhone, iPad, Watch, and widget targets.
- Cursornow should consume a tagged `UsageSync` release through Swift Package Manager. The two apps
  share a versioned snapshot contract and CloudKit schema, not source-tree ownership.

## Current foundation

- `UsageSync` contains the platform-neutral, versioned snapshot schema.
- `CloudKitCoreDataSnapshotStore` uses `NSPersistentCloudKitContainer` and the user's private CloudKit
  database.
- `UsageSnapshotWriting` is available only on macOS; mobile and Watch clients receive the reader API.
- The Core Data model is created programmatically so every Apple target uses the same schema.
- CloudKit-compatible fields are optional, and the store has no Core Data unique constraints.
- The Mac publisher has a separate, opt-in **Sync to Apple Devices** setting and never exports
  credentials, raw logs, or raw provider responses.

The older iCloud Documents implementation for additive multi-Mac history remains in the imported
codebase for compatibility work, but it is not wired into the superUsage composition root and is not
the mobile transport.

## Snapshot contract

`CloudUsageSnapshot` is the transport boundary. It includes a schema version, source device, monotonic
revision, generation date, and normalized providers and metrics.

Core Data and CloudKit are repository implementation details. SwiftUI views consume decoded snapshot
values rather than managed objects, keeping the planned UI redesign independent of persistence.

## Apple identity plan

All new resources must belong to Chengdu Weisen Quwan Technology Co., Ltd:

- Team ID: `C554753V8P`
- Planned macOS bundle ID: `com.weisenjoytech.superusage`
- Existing Cursornow mobile bundle ID: `com.weisenjoytech.Cursornow`
- Existing Cursornow App Store Apple ID: `6746765552`
- Planned shared container: `iCloud.com.weisenjoytech.usage.sync`

Never create or sign these resources with the personal team `TP656CVH5C`. The previous personal-team
container `iCloud.com.linliao.openusage.sync` was only an MVP probe and is not part of this product.

## Implementation status

The snapshot model, CloudKit-backed Core Data repository, Mac publisher, and replaceable mobile/watch
prototype have been exercised during MVP development. The prototype proved the direction but did not
establish the enterprise product resources.

Before a signed end-to-end enterprise build:

1. Register the planned macOS bundle ID and shared CloudKit container under team `C554753V8P`.
2. Assign the container to both superUsage and the existing Cursornow identifiers.
3. Create fresh development profiles with the CloudKit entitlement and explicit `Development`
   environment.
4. Integrate the tagged `UsageSync` package into the private Cursornow repository.
5. Verify a real Mac publish and iPhone read using the same iCloud account.
6. Validate the schema, then deploy it to Production before external distribution.

WatchConnectivity can be added later as a phone-to-Watch refresh optimization. It does not change the
Mac-only authority rule.

## Future non-Apple clients

When an Android, Fire, third-party e-ink, or web client is planned, add an optional Supabase repository
beside the CloudKit repository. The Mac may publish to both destinations when the user enables
cross-platform sync. Apple clients continue using CloudKit by default, and all clients remain
read-only.

Use authentication or device pairing, strict per-user row-level security, and optionally client-side
payload encryption. Provider credentials and source logs never leave the Mac.
