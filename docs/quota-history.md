# Usage History

The dashboard answers *how much is left right now*. Usage History answers the questions a single number
can't: how fast the quota drained over the last few hours, when the burn accelerated, and whether a
window actually reset or the app simply stopped getting data.

## Opening it

Footer **Options ▸ Usage History…**. It opens in its own window, so it can be left on a second display
or beside your editor while you work. The window remembers its size and position.

## What you see

Pick a provider, one of its metrics, and a range (**24h**, **7d**, **30d**). The chart plots how much of
the window was **left** over time.

Everything is drawn as a share of the window (0–100%), whatever the metric's own unit is, so a percent
meter, a dollar balance, and a credit pool all read on one axis. The absolute figure isn't lost — point
at the chart and the readout gives it in the metric's own unit, along with the time.

Three things the chart deliberately refuses to draw as usage, because each would misrepresent your burn
rate:

- **Resets** — when a window rolls over, the quota refills. The line breaks and a dashed marker with a ↺
  sits at the boundary, instead of a vertical climb that would look like quota appearing out of nowhere.
- **Gaps** — no successful refresh means no observation. If the Mac slept, the network was down, or the
  provider kept failing, the line simply stops and picks up again afterwards. It is never interpolated
  across, which would invent a smooth burn through hours nobody measured.
- **Movement inside a point** — each point is the value at the *end* of its bucket, with a soft band
  behind the line showing the highest and lowest readings within it. A spike inside an hour stays
  visible rather than being averaged away.

A line under the chart counts the resets and gaps in view, so a break always has a stated reason.

## Where the data comes from

Every time a provider refreshes successfully, superUsage records one point for each of that provider's
metrics that has a limit — the same numbers the dashboard meters show. Refreshes happen every 5 minutes
(see [Refreshing](refreshing.md)), so that's the natural resolution of the data.

Points are stored raw, at that 5-minute cadence, and grouped into buckets only when a chart is drawn:
the 24h view reads at 15 minutes per point, the 7d and 30d views at one hour. Storing the raw points
rather than pre-rolled hourly averages is what lets the same data answer a fine-grained day view and a
month view, and what lets resets be located exactly instead of guessed at.

Some consequences worth knowing:

- **Failed refreshes record nothing.** A failure leaves a gap on purpose — that's what makes "the quota
  stopped moving" distinguishable from "we stopped being able to look".
- **A cached refresh records nothing.** When a refresh is served from cache, no new observation
  happened, so no new point is invented.
- **`superusage --force` records too.** A refresh driven from the command line is a real observation, so
  it lands in the same history the app writes. Without that, driving refreshes from the terminal would
  punch holes in the chart for refreshes that actually succeeded.
- **Each account is its own history.** Series are keyed by the account that produced them, not just by
  the provider, so signing out and into a different account starts a fresh line instead of continuing the
  previous account's. If the app can't tell which account a refresh belongs to, it records nothing for
  that pass — a gap can be filled in later, but usage from two accounts merged into one line can't be
  separated afterwards. superUsage reads which account is signed in where **once per launch** (the same
  pass that decides which account cards exist at all), so if you swap accounts while it's running, quit
  and reopen it — until you do, the whole app, history included, still attributes to the previous
  account.
- **Metrics without a limit never appear.** Daily spend, token counts, and the Usage Trend chart are
  unbounded, so there's no "remaining" to plot. They stay on the dashboard.
- **History starts when you update.** The chart fills in from the first refresh after this version is
  installed; there is no back-fill of usage from before then.

## Storage, retention, and privacy

History lives in a local database at
`~/Library/Application Support/superUsage/superUsageQuotaHistory.sqlite` — the same folder the app's
other local caches use, so the menu-bar app and the `superusage` command-line tool read and write one
shared history rather than two.

- **Local only.** It is never written to iCloud and never sent anywhere. Unlike the current-values
  snapshot that [iCloud Sync](icloud-sync.md) can publish to your other Apple devices, quota history
  stays on the Mac that recorded it — every Mac keeps its own.
- **Only numbers and timestamps.** Each row holds a metric id, a time, a used and a limit value, and the
  window's reset time. No credentials, no provider responses, no log contents.
- **Bounded retention.** Points older than **35 days** are deleted. Pruning runs at most once a day, off
  the refresh path. The 35-day window covers the longest chart range (30 days) with room for a Mac that
  was asleep across a window boundary.

Deleting the file resets the history; the app recreates it and starts recording again on the next
refresh. Nothing else in the app depends on it.
