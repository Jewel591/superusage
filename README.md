# superUsage

superUsage is an open-source macOS menu-bar app for monitoring usage across AI coding providers.
It reads credentials and usage data already available on your Mac, normalizes the results, and keeps
provider secrets on the Mac.

The project is currently preparing its first public release.

## Apple sync architecture

The Mac is the only writer and the source of truth. It can publish normalized, credential-free
snapshots through a private CloudKit database.

- **superUsage for macOS:** reads provider credentials and logs, calls provider APIs, calculates
  usage, and publishes snapshots.
- **Cursornow for iPhone, iPad, and Apple Watch:** reads and displays snapshots. It does not receive
  provider credentials or call provider APIs.
- **UsageSync:** the public, transport-neutral SwiftPM library shared with the private Cursornow
  client repository.

CloudKit is the default Apple transport. A future Supabase adapter may be added for read-only
Android, web, or third-party e-ink clients without replacing CloudKit or changing the Mac authority.

## Build

Requirements:

- macOS 15 or later
- Swift 6.2 toolchain

```bash
swift build
swift test
```

The local signed app-bundle script requires an Apple Development identity and a matching
provisioning profile:

```bash
./script/build_and_run.sh build
```

Forks can use `swift build` and `swift test` without Apple signing credentials.

## Privacy

Provider cookies, OAuth tokens, API keys, raw logs, and raw provider responses are never included in
CloudKit snapshots. See [Privacy](docs/privacy.md) and
[Apple client architecture](docs/apple-client-architecture.md).

## License and attribution

The source is available under the MIT License. superUsage is derived from
[OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers. The OpenUsage name, logo, and
visual identity are not used by this project. See [NOTICE.md](NOTICE.md).
