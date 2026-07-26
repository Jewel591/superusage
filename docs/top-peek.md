# Top Peek

Push the pointer into the top edge of your screen and your starred metrics slide out from under the
menu bar. Move away and they're gone.

Top Peek is off by default. Turn it on in Settings → Appearance → **Top Peek**.

## How it appears

- **Push the pointer all the way into the top edge**, near the middle of the screen. It has to reach
  the edge and rest there for a moment — brushing past the menu bar on your way somewhere else won't
  bring it out.
- The panel appears just below the menu bar, centered.
- **Move down onto the panel** and it opens into the full readout.
- Move away from it and it goes away on its own, after a short grace period so an overshoot doesn't
  cost you the panel you were reaching for.

The left and right ends of the menu bar are deliberately not part of the trigger, so reaching for the
Apple menu or your other menu bar items never brings it out.

## What it shows

Top Peek shows your **starred metrics** — the same ones in the menu bar strip. Star them from any
row's right-click menu or from Customize; see [Menu bar](menu-bar.md#starring).

Compact, at a glance:

- One segment per starred provider: its mark, then that provider's values.
- A value turns yellow or red when that metric is pacing toward its limit, so trouble is visible
  without opening anything.

Expanded, after you move onto it:

- Every starred metric with its meter, value, and reset time.
- Refresh status in the header — click it to refresh now. A warning triangle appears when a
  provider's last refresh failed; the popover has the reason.
- **Open superUsage** and **Settings** buttons.

With more starred metrics than fit on your screen, the list scrolls inside the panel — the header and
the buttons stay put.

When there's nothing to show, the panel says which of the reasons it is:

- **Nothing starred yet** — it says so, and opens Customize when clicked.
- **Still loading**, or nothing fetched yet — it says it's updating, rather than telling you to go star
  something you already starred.
- **Every starred provider failed to refresh** — it says so and opens the popover, where the reason is.

## Keyboard

Record a **Peek Shortcut** in Settings → Appearance to open the full readout from anywhere. A panel
opened this way stays up — it ignores the pointer entirely — until you press the shortcut again or
click somewhere else. (Without a shortcut recorded, the pointer gesture is the only way in.)

## Where it behaves

- **Notched and non-notched Macs:** the panel hangs below whatever the menu bar's real height is, so
  it never rides up into it.
- **Multiple displays:** it appears on whichever screen you push the pointer to the top of. Unplug a
  display while it's showing and it goes away rather than stranding itself off-screen.
- **Full-screen apps and auto-hidden menu bars:** the panel still leaves room for the menu bar that
  the same gesture slides down, so the two never overlap.
- **Spaces:** it follows you rather than staying behind on one desktop.
- It never takes keyboard focus, so whatever you were typing in keeps it.
- With macOS **Reduce Motion** on, the panel appears and disappears without the slide.

## Privacy

Top Peek honors **Hide From Screen Share** (Settings → Privacy). While your screen is being shared or
recorded, the panel says your usage is hidden instead of showing numbers — the same protection the
menu bar strip gets. See [Menu bar](menu-bar.md#hiding-usage-while-screen-sharing).

## Menu bar, popover, or peek?

All three show the same data, at different depths:

- The **menu bar strip** is always there, and shows values only.
- **Top Peek** is absent until you ask for it, and adds meters, reset times, and refresh status.
- The **popover** is the full dashboard — every metric, every provider, history, and settings.
