# Ships Trade Analyzer

Brings the analysis of [X4 Player Ship Trade Analyzer](https://www.nexusmods.com/x4foundations/mods/1801) into the game itself. No save file, no external tool, no game folder to point at: the mod reads the trade log the game already keeps for your ships and shows you who is earning, on what, and how well loaded they ran.

## Features

- **Two analysis modes**:
  - **By Transactions** - every buy and sell is counted on its own. Faster and shows more, but profit is estimated against the ware's average price.
  - **By Trades** - buys are matched against the sells that emptied the hold again, so profit is real. Shows fewer rows, since a ship still carrying cargo has no completed trade yet.
- **Five views**, both modes:
  - **Details** - the full table for the selected ship, newest first.
  - **Profit over Time** - cumulative profit per ship as a line graph, up to 8 ships at once.
  - **Ships by Wares** - ranked bars, one per ship, split by the wares it traded.
  - **Wares by Ships** - the same, transposed: one bar per ware, split by the ships that carried it.
  - **Cargo Load** - how full each ship actually ran, average and best.
- **Inject Internal** \(on by default\) - an artificial try to avoid game engine limitations.
- **Filters** applying to every view, by assigned station, by ship size, by cargo type, etc.
- **Sorting** of the ship list by name or by estimated profit, with the filtered total shown above it.
- **Reverse order** on the ranked views, to look at the bottom of the ranking instead of the top.

## Requirements

- `X4: Foundations` 8.00 and 9.00.
- `Mod Support APIs` by [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659) to be installed and enabled. Version `1.95` and upper is required.
  - It is available via Steam - [SirNukes Mod Support APIs](https://steamcommunity.com/sharedfiles/filedetails/?id=2042901274)
  - Or via the Nexus Mods - [Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503)
- `Options Helper`, to provide the in-game Debug Level option. Version `1.10` and upper is required.
  - It is available via Steam - [Options Helper](https://steamcommunity.com/sharedfiles/filedetails/?id=3715253556)
  - Or via the Nexus Mods - [Options Helper](https://www.nexusmods.com/x4foundations/mods/2089)
- `Print Extension List`, to record the game version and the enabled extensions in the log. Version `1.01` and upper is required.
  - It is available via Steam - [Print Extension List](https://steamcommunity.com/sharedfiles/filedetails/?id=3770927339)
  - Or via the Nexus Mods - [Print Extension List](https://www.nexusmods.com/x4foundations/mods/2191)

## Notes and limitations

- The game engine does not provide data for trading between players' ships and player stations, despite the fact that information is stored in the game memory and later in the save file. This mod cannot show those trades, and they are not counted in the profit totals.
- Ships that have been destroyed or sold no longer appear.
- Profit in By Transactions mode is an estimate. For container wares it compares against the ware's average price; for mined solids, liquids and gases there is no purchase to compare against, so the whole sale counts as profit.

## Installation

- **Steam Workshop**: [Ships Trade Analyzer](https://steamcommunity.com/sharedfiles/filedetails/?id=0).
- **Nexus Mods**: [Ships Trade Analyzer](https://www.nexusmods.com/x4foundations/mods/)

## Usage

Right-click any player-owned ship and pick **Trade Analyzer**.

Opening will preselects that ship, if ship has transactions in the log. Otherwise, the first ship in the list is selected.

A ship is picked by making its row the current one in the list on the left, exactly like the object list on the map.

**Profit over Time** draws several ships at once, so there the list works like the map's as well: ctrl-click adds or removes a ship, shift-click takes a range, and a plain click goes back to a single one. Up to 8 lines are drawn - picking a ninth ship drops the one picked first.

The data is read when the menu opens, and read again on a later open once the last reading is older than the **Data Refresh Interval** - one in-game minute by default. Press **Refresh** to read it again at any time.

## Settings

Found under Extension Options.

- **Data Refresh Interval** - how old the last reading may be before opening the menu takes a new one, 0 to 10 in-game minutes. At 0 every open re-reads the trade log; at 10 a reading is kept for ten minutes and only **Refresh** replaces it sooner.
- **Internal Trades Separation** - used by **Inject Internal**: two trades of the same ware in the same direction further apart than this came from separate visits to the home station, 5 to 30 in-game minutes. Lower it for short local runs, raise it for long hauls. Changing it re-reads the trade log on the next menu open.
- **Debug Level** - None, Debug or Trace. Leave at None unless you are reporting a problem.

## Credits

- Author: Chem O`Dun, on [Nexus Mods](https://next.nexusmods.com/profile/ChemODun/mods?gameId=2659) and [Steam Workshop](https://steamcommunity.com/id/chemodun/myworkshopfiles/?appid=392160)
- *"X4: Foundations"* is a trademark of [Egosoft](https://www.egosoft.com).

## Acknowledgements

- [EGOSOFT](https://www.egosoft.com) — for the X series.
- [SirNukes](https://next.nexusmods.com/profile/sirnukes?gameId=2659) — for the Mod Support APIs that power the UI hooks.

## Changelog

### [1.00] - 2026-08-??

- **Added**
  - Initial release.
