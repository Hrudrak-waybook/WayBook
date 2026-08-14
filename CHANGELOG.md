# WayBook changelog

## 1.26.26

- There is now a user guide: https://hrudrak-waybook.github.io/WayBook/
- Auto-tagging is a setting. "Auto-tag NPCs" in Options turns it off entirely, and three checkboxes under it pick which tags you want: Rare/Elite, Rep faction, and Profession.
- A newly added waypoint flashes its row three times, so you can see where in the list it landed.
- A button beside the Edit window's Coordinates field stamps in your current position, which fixes any waypoint you saved while standing a long way from what you had targeted.
- The Options window is three columns wide, so nothing sits far below the fold.

## 1.26.20

Everything since 1.26.5.

### New

- Group and sort controls now sit on the main window, under the search box, with an arrow button to flip the sort direction.
- Coordinates can be edited in the Edit window, and the waypoint moves to match.
- Waypoints created from a selected target are tagged automatically with Rare, Elite, the NPC's reputation faction, and its role such as Flight Master or Quartermaster.
- The Edit window has a Close button.
- Tab moves between the Edit window's fields, and Shift-Tab moves back.

### Improved

- Adding a waypoint from a target confirms it in chat and scrolls the list to the new row.
- WayBook is much quieter, with seven routine chat messages removed.
- The Tags column greys out while grouping by tag, the way the Zone column already did.

### Fixed

- The tag dropdown closes when you click away from it.
- Hovering the tag picker or a confirmation box no longer collapses the window to the text bar mid-click.
- Collapsing to the text bar leaves the Options, Export, Share and Edit windows open, since only closing the main window should close them.
- The Edit window's layout no longer overlaps itself when a waypoint has several tags.

## 1.26.5

- American spellings throughout.

## 1.26.4

- The version number and license now show at the bottom of the Options window.

## 1.26.3

- Questie's tracker no longer shows through the WayBook window.

## 1.26.2

- Every WayBook window is now fully opaque, so the game world no longer shows through.

## 1.26.1

- Fixed the new collapse bar shrinking the window while the mouse was still inside it.

## 1.26.0

- New optional "Auto-collapse to text bar", which shrinks WayBook to a small draggable bar shortly after your mouse leaves it, and restores the window when you hover the bar. Off by default.

## 1.25.1

- Waypoints that Questie creates for a tracked objective now get the "Quest" tag automatically.
- The tag picker no longer accumulates tags you have stopped using.
- Clicking a waypoint on another continent now says so instead of claiming the arrow was set.

## 1.25.0

- Any waypoint tagged "Quest" shows a book icon at the start of its row.

## 1.24.6

- The arrow no longer jumps to the next-nearest waypoint when the current one clears.

## 1.24.4

- Added a setting to stop the arrow being reassigned when a waypoint clears.

## 1.24.3

- Fixed "Keep waypoints on arrival" also keeping Questie's quest waypoints alive.

## 1.24.2

- Tightened the Edit window's spacing so a waypoint with no tags no longer leaves a large gap.

## 1.24.1

- Tags in the Edit window now wrap as pill chips and the window grows to fit however many there are.
- Closing the main window closes the Options, Export, Share and Edit windows with it.

## 1.24.0

- Right-click now opens a single Edit window covering the label, note and tags together, replacing the old alt-click and ctrl-click.
- Tags are picked from a dropdown and removed by clicking their chip.

## 1.23.0

- "Add Target" became "Add Waypoint" and now works with nothing selected, saving your position and opening it for renaming.

## 1.22.5

- "Keep waypoints on arrival" now applies to waypoints you already had, not just new ones.

## 1.22.4

- Added an optional colorblind-friendly color scheme using the Okabe-Ito palette.
- Swapped the Zone and Tags entries in "Show in the list", and simplified the Options headings.

## 1.22.3

- Options is now split into labeled sections rather than one long list.

## 1.22.2

- Tag badges gained rounded corners and tighter padding.

## 1.22.1

- Grouping by tag now lists a waypoint under a header for every tag it has, not just the first one alphabetically.
- Tag badges are hidden while grouping by tag, where they only repeated the header.
- Fixed the Options window's right-hand column overlapping the left.

## 1.22.0

- Tags replaced the single category: define a tag once, reuse it anywhere, and give a waypoint as many as you want.
- Tags show as small badges under each row instead of taking up a text column.

## 1.21.0

- First version of per-waypoint categories, with a three-way "Group by" replacing the old group-by-zone checkbox.

## 1.20.1

- "Send to Chat" now inserts the /way command itself rather than a sentence describing it.

## 1.20.0

- Shift-click a waypoint to open a Share window with a copyable /way line and a Send to Chat button.

## 1.19.2

- Removed a misleading hint from the Export window. Export honoring your search is intended.

## 1.19.1

- Fixed the Export window drawing behind the Options window that opens it.

## 1.19.0

- New "Export Waypoints" button in Options, producing a selectable text dump of every waypoint as /way lines with notes as comments.

## 1.18.0

- Label is now the only column shown by default.
- Distance moved into its own right-aligned column so the readings line up.

## 1.17.0

- New Distance column and a nearest-first sort, both updating live as you move.

## 1.16.0

- New search box, filtering as you type across labels, zones and notes.

## 1.15.0

- Grouping by zone now unticks and greys out the Zone column, restoring it when you turn grouping off.

## 1.14.2

- Fixed an error that stopped the addon loading.

## 1.14.1

- Key bindings moved out of Bindings.xml and into the addon itself.

## 1.14.0

- Delete a waypoint with the red minus button, with a confirmation first.
- Right-click opens notes, and the button tooltips show your current key bindings.
