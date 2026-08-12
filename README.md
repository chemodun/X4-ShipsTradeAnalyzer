# Ships Trade Analyzer

Brings the analysis of [X4 Player Ship Trade Analyzer](https://www.nexusmods.com/x4foundations/mods/1801) into the game itself. No save file, no external tool, no game folder to point at: the mod reads the trade log the game already keeps for your ships and shows you who is earning, on what, and how well loaded they ran.

**Important**: the game only records trade logs for ships flown by AI pilots. A ship you fly yourself produces no entries, and neither does one without a pilot.

## Features

- **Two analysis modes**
  - **By Transactions** - every buy and sell is counted on its own. Faster and shows more, but profit is estimated against the ware's average price.
  - **By Trades** - buys are matched against the sells that emptied the hold again, so profit is real. Shows fewer rows, since a ship still carrying cargo has no completed trade yet.
- **Five views**, both modes:
  - **Details** - the full table for the selected ship, newest first. Time, operation, ware, station, sector, price, quantity, total, estimated profit and cargo load. In By Trades mode a row instead shows what the trade bought, sold and earned, how long it took, how many gates it crossed and how full the hold ran, and expands to the individual buy and sell legs behind it. A busy ship is paged rather than scrolled, so a page always holds exactly what the screen shows.
  - **Profit over Time** - cumulative profit per ship as a line graph, up to 8 ships at once.
  - **Ships by Wares** - ranked bars, one per ship, split by the wares it traded.
  - **Wares by Ships** - the same, transposed: one bar per ware, split by the ships that carried it.
  - **Cargo Load** - how full each ship actually ran, average and best.
- **Filters** applying to every view - **With Transactions** \(on by default: only ships that have something in the trade log\), parent station \(any, none, or one specific station\), ship class \(XL, L, M, S\) and cargo type \(container, solid, liquid, gas\). The parent-station list follows the ships being shown, so turning **With Transactions** off also brings in the stations whose ships never trade - the game does not log deliveries between your own ships and your own stations, so a station's own miners never appear in the trade log at all.
- **Inject Internal** \(on by default\) - a ship assigned to a station only has its outside half logged: it sells a load the log never saw it buy, or buys one the log never saw it deliver. Where the cargo does not add up, the missing half at the home station is filled in - same ware and quantity, and dated between the two logged stops by the gates flown either side of the detour. It is priced at what the home station charges for that ware, which means **the price has to be one you set yourself**: a ware the station prices automatically is priced against its own stock and there is no way to know what that price was at the time, so nothing is invented for it. Turn the setting off to see the trade log exactly as the game keeps it.
- **Sorting** of the ship list by name or by profit, with the filtered total shown above it.
- **Reverse order** on the ranked views, to look at the bottom of the ranking instead of the top.
- **No cut-off ranking**. The bar views fit as many bars as the screen has room for and page through the rest, so nothing is hidden behind a "top 25". The colour legend sits at the bottom of the screen and scrolls when it is long.
- **Room for more bars**. The bar and cargo-load views hide the ship list on the left and show its count instead, since every row it draws is one a bar cannot have. Turn **Show Legend** off to reclaim its band at the bottom as well, and lower **Bar Detail** to put fewer bar tables side by side - each one costs a row per bar and buys 13 more colour segments.

## Usage

Right-click any player-owned ship or station and pick **Trade Analyzer**.

Opening it on a ship preselects that ship. Opening it on a station preselects that station as the parent-station filter, so you immediately see just the ships assigned to it - and if none of them has traded, **With Transactions** is turned off for you so you still see the ships rather than an empty list.

A ship is picked by making its row the current one in the list on the left, exactly like the object list on the map. **Profit over Time** draws several ships at once, so there the list works like the map's as well: ctrl-click adds or removes a ship, shift-click takes a range, and a plain click goes back to a single one. Up to 8 lines are drawn - picking a ninth ship drops the one picked first.

The data is read when the menu opens, and read again on a later open once the last reading is older than the **Data Refresh Interval** - one in-game minute by default. Press **Refresh** to read it again at any time.

## Settings

Found under Extension Options.

- **Data Refresh Interval** - how old the last reading may be before opening the menu takes a new one, 0 to 10 in-game minutes. At 0 every open re-reads the trade log; at 10 a reading is kept for ten minutes and only **Refresh** replaces it sooner.
- **Debug Level** - None, Debug or Trace. Leave at None unless you are reporting a problem.

## Requirements

- [SirNukes Mod Support APIs](https://www.nexusmods.com/x4foundations/mods/503)
- [Options Helper](https://www.nexusmods.com/x4foundations/mods/1660)
- [Print Extension List](https://www.nexusmods.com/x4foundations/mods/1793)

## Notes and limitations

- Ships that have been destroyed or sold no longer appear. Their trades live on in the player account log, but the ship itself is gone from the game and cannot be listed.
- Profit in By Transactions mode is an estimate. For container wares it compares against the ware's average price; for mined solids, liquids and gases there is no purchase to compare against, so the whole sale counts as profit.
- Ships carrying scrap always read as fully loaded - the game does not report a usable per-unit volume for it.
- The game's UI has no bar chart widget, so the ware breakdowns and the load view are drawn as horizontal bars rather than column charts.
- **Jumps** counts gates, using the galaxy's own gate network - including sectors you have not explored yet. In By Trades it is the gates between the stations one trade visited; in By Transactions it is the gates flown to reach that stop from wherever the ship traded before, counted over its whole log rather than over the rows a filter left visible. It reads as a dash when a sector cannot be resolved or no gate route connects them.

## Credits

- Author: Chem O`Dun
- In-game counterpart of [X4 Player Ship Trade Analyzer](https://github.com/chemodun/X4PlayerShipTradeAnalyzer), which analyses the same data out of a save file.
- Not affiliated with Egosoft. "X4: Foundations" is a trademark of its respective owner.

## Changelog

### [1.00] - 2026-08-??

- **Added**
  - Initial release.
