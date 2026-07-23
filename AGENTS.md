# AGENTS.md

superUsage is an open-source SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider
usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This public repository contains the superUsage macOS app and the shared
> `UsageSync` SwiftPM product. The Cursornow mobile clients remain in the private
> `Jewel591/Cursornow` repository.

## Releases

`main` is the active development line; tags ship through `.github/workflows/release.yml` with a
Sparkle appcast on `gh-pages`.

### Product owner and signing team (fixed decision)

- Develop, provision, test CloudKit, distribute, and publish superUsage and Cursornow with the
  **Chengdu Weisen Quwan Technology Co., Ltd** Apple Developer account only. Its Team ID is
  `C554753V8P`.
- This Mac also has the `TP656CVH5C` personal identity installed. Never use that team for these
  products or their App IDs, iCloud containers, provisioning profiles, TestFlight builds, or App
  Store records.
- Keep `DEVELOPMENT_TEAM = C554753V8P` explicit in Xcode projects. Before a signed build, inspect the
  resolved build settings, certificate OU, and embedded provisioning profile.
- The planned macOS Bundle ID is `com.weisenjoytech.superusage`. The shared CloudKit container is
  planned as `iCloud.com.weisenjoytech.usage.sync`. Treat both as pending until their availability
  and registration are confirmed in the enterprise team.

### Guardrails (do not break)
- **Never choose or increase a release version on your own initiative.** Propose a version and wait
  for explicit owner approval before changing release metadata, tagging, or publishing.
- Beta releases use `-beta.N` tags and stay GitHub pre-releases on Sparkle's beta channel. Stable releases use plain tags and become GitHub "Latest".
- Never leave a release in Draft and never ship blank notes.
- Never commit certificates, provisioning profiles, notarization credentials, Sparkle private keys,
  API keys, provider credentials, or user data. Public CI receives signing material only through
  GitHub Actions secrets.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

### Apple clients and sync authority (fixed decisions)

- **The Mac is the only writer and the source of truth for usage data.** It owns provider credentials,
  local-log scanning, API calls, normalization, pricing, and snapshot publication.
- Cursornow on iPhone, iPad, and Apple Watch is a read-only display client. It must never import provider
  credentials, call provider APIs on the user's behalf, or mutate usage snapshots.
- Apple-platform snapshot transport uses a private CloudKit database mirrored through Core Data with
  `NSPersistentCloudKitContainer`. The transport-neutral types and repository live in the
  `UsageSync` package product; client UI must depend on those types instead of Core Data entities or
  `CKRecord` directly.
- The read/write boundary is deliberate: `UsageSnapshotWriting` is macOS-only at compile time, while
  `UsageSnapshotReading` is available to Apple display clients.
- Mobile UI is expected to change substantially. Keep it replaceable and do not move sync, schema, or
  provider logic into SwiftUI views.
- Apple Watch is a read-only surface. The Watch app reads the shared CloudKit-backed
  Core Data replica directly. WatchConnectivity may be added later as a timely, battery-efficient cache
  delivery optimization, but must not make the phone a writer or authority.

### Cross-platform enhancement route (future, not current scope)

- CloudKit remains the default Apple-only path. If Android, Fire tablets, third-party e-ink devices, or
  the web become product targets, add Supabase as an **optional second transport adapter** rather than
  replacing CloudKit.
- The Mac authority may fan the same versioned `CloudUsageSnapshot` out to CloudKit and, when explicitly
  enabled by the user, Supabase. Do not replicate from an iPhone or make a display client authoritative.
- Non-Apple clients remain read-only. Use device pairing or user authentication plus strict row-level
  security. Never upload provider cookies, OAuth tokens, API keys, raw logs, or raw provider responses.
- Keep the snapshot schema transport-neutral and versioned so CloudKit records, Supabase rows, and any
  future encrypted payload all encode the same domain object. Add a new repository implementation,
  not Supabase conditionals throughout the app.

## Providers

Conventions for the per-provider modules under `Sources/SuperUsage/Providers/<Name>/`.

- **Structure:** one folder per provider with an auth store (reads credentials already on the user's machine), a usage client (calls the provider API), and a mapper (normalizes to `MetricLine`), conforming to `ProviderRuntime` — `refresh()` plus `hasLocalCredentials()`, the local-only credential probe used by first-run detection (`FirstRunSeeder`) and by new-provider detection on the first launch after the provider ships (`NewProviderSeeder`); mirror the same local credential sources and usability filters that `refresh()` starts with, reusing the auth-store loaders instead of adding a second credential-reading path. See `docs/adding-a-provider.md` and `docs/provider-enablement.md`.
- **Model pricing:** all spend imputation (Claude, Codex, Cursor, Grok) prices through the shared engine in `Sources/SuperUsage/Pricing/` (see `docs/pricing.md`). Cursor-native model rates and alias rules live in `Sources/SuperUsage/Resources/pricing_supplement.json` — sync new or changed models from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md) (update `updated_at`, pricing entries, and `alias_rules` for CSV model slugs); merging to `main` publishes it to gh-pages, so installed apps pick it up without a release. The bundled LiteLLM/models.dev snapshots regenerate with `script/update_pricing_snapshots.sh` (a release-time chore).
- **Default order:** Claude, Codex, Cursor first (the established providers, in that order), then every other provider alphabetically by display name (Antigravity, Devin, Grok, …). The order is the array order in `AppContainer`, which seeds `LayoutStore`'s default provider order (and `resetToDefault`). A new provider slots into the alphabetical tail.
- **Metric placement defaults:** when adding or changing a metric, confirm its four defaults with the owner before choosing — never pick silently:
  1. enabled on/off (`DefaultLayout.metricIDs`),
  2. Always Visible vs. On Demand — above the fold vs. behind the per-provider caret (`DefaultLayout.expandedMetricIDs`). Note: a provider always keeps at least one Always Visible row — the dashboard promotes all metrics when every one is marked On Demand, so a fully On Demand provider isn't possible; leave one metric Always Visible for the caret to appear,
  3. pinned to the menu bar (`DefaultLayout.pinnedMetricIDs`),
  4. order (within a provider, the `widgetDescriptors` declaration order).

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before testing.

## Pull Requests

Every PR description must follow this structure so reviewers can skim it quickly:

- **TL;DR** — open with a one- or two-sentence plain-English summary of the change.
- **What was happening** — plain-English bullet points describing the prior behavior, bug, or gap that motivated the change.
- **What this changes** — bullet points describing what the PR actually changes.
- **Heads-up** (optional) — noteworthy things a reviewer or future maintainer should consider (risks, follow-ups, trade-offs).
- **Tests** (optional) — how the change was verified.
- **Screenshots** (optional in general, but **required for any PR that makes a visual change**) — images of the affected UI after the change.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- Add a regression test when fixing a bug, where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- When adding a provider, follow the conventions in "## Providers".

## Error Handling

Always fail loudly into error logging (log file, PostHog) and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- The exact user-facing brand spelling is `superUsage`. Swift modules and type names use
  `SuperUsage` according to Swift naming conventions.
- Match the existing design language; superUsage has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
