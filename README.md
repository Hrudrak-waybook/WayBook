# WayBook

An address book for your TomTom waypoints.

WayBook turns the waypoints you already save with TomTom into a browsable,
searchable list. Click a row and the crazy arrow points at it. Give any
waypoint a note and as many reusable tags as you want, and WayBook tracks how
often you go there and when you were last there.

**Requires [TomTom](https://www.curseforge.com/wow/addons/tomtom).** WayBook
does nothing on its own.

**[Read the user guide](https://hrudrak-waybook.github.io/WayBook/)** for the
full walkthrough.

Built for Mists of Pandaria Classic. A Retail build exists but has not been
tested yet.

## Features

- **Search** across labels, zones and notes. Space-separated words are ANDed,
  so `bank org` and `org bank` both find the Orgrimmar bank.
- **Group** by zone, by tag, or not at all. Grouping by tag is true
  many-to-many: a waypoint tagged "Auctioneer, Klaxxi, Quartermaster" appears
  under all three headers.
- **Tags** you define once and reuse, shown as small pill badges under each
  row. Unused tags prune themselves out of the picker automatically.
- **Notes** per waypoint, free text, searchable.
- **Visit tracking** with a count and a last-visited timestamp.
- **Distance column** and a nearest-first sort, both live-updating as you move.
- **Choose your columns**: label, zone, tags, coordinates, visits, distance.
- **Book icon** on any waypoint tagged "Quest". Locations added through
  Questie get that tag automatically.
- **Share** a waypoint as a `/way` line, copyable or inserted into your chat
  box, by shift-clicking a row.
- **Export** the whole book, or just what your search currently matches.
- **Auto-collapse to a text bar**, opt-in, so WayBook stays available without
  occupying the screen. Hover the bar to bring the window back.
- **Colorblind-friendly palette** as an option, using the Okabe-Ito color set.
- **Four key bindings**, none set by default.

Everything is saved per character. Different characters want to remember
different places.

## Installation

Install through the CurseForge app, or drop the `WayBook` folder into
`World of Warcraft\_classic_\Interface\AddOns\`. Install TomTom first.

## Slash commands

| Command | Result |
|---|---|
| `/waybook` or `/wb` | Open the main window |
| `/waybook options` or `/wb config` | Open the Options window |

## Key bindings

Set these yourself under **Key Bindings → WayBook**. None are bound by
default.

| Action |
|---|
| Toggle waypoint list |
| Toggle options |
| Add waypoint |
| Clear the arrow |

## Row interactions

| Action | Result |
|---|---|
| Left-click | Point the arrow at this waypoint |
| Right-click | Open the Edit window for label, note and tags |
| Shift-click | Open the Share window |
| Red minus | Delete, with confirmation |

## License

MIT. See [LICENSE](LICENSE).
