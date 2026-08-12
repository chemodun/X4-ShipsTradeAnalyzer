-- Ships Trade Analyzer - menu.
--
-- Standalone top-level menu, registered the way vanilla registers TransactionLogMenu
-- and opened from the interaction menu of a player ship or station. Left panel:
-- view, mode, filters and the ship list. Right panel: the selected view.
--
-- A ship is picked the way the map's object list picks one - the current row is the
-- selection - and only the graph, which draws several at once, is multiselect.
--
-- The X4 graph widget draws lines and nothing else, so the breakdowns are horizontal
-- bars built from background-coloured table cells. Those cannot be kept in sync
-- across tables, so they are paged to fit rather than scrolled.

---@diagnostic disable-next-line: unresolved-require
local ffi       = require("ffi")
local C         = ffi.C

---@diagnostic disable-next-line: unresolved-require
local sta       = require("extensions.ships_trade_analyzer.ui.sta_data")
---@diagnostic disable-next-line: unresolved-require
local staTrades = require("extensions.ships_trade_analyzer.ui.sta_trades")

local PAGE = 1972092439

local menu = {
  name            = "ShipsTradeAnalyzerMenu",
  lastRefreshTime = 0,
  updateInterval  = 0.1,
}

local config = {
  infoLayer        = 4,
  -- Share of the map's own left info panel width, and vanilla's floor for it.
  leftPanelShare   = 1,
  mapInfoMinWidth  = 400,
  -- A table caps at 13 columns, so a bar spans barTables of them side by side.
  -- Each one costs a row of the frame's pool per item: the Bar Detail trade.
  maxTableCols     = 13,
  barTables        = 2,
  barTablesMax     = 6,
  -- Label and Total column of the bar views.
  labelAndTotalColShare     = 0.8,
  -- Label column of the Cargo Load view.
  nameColShare     = 0.6,
  -- Upper bound of each fixed-width column, measured off the formatted string.
  widthSample = {
    price = 9999999, quantity = 999999, total = 999999999, load = 100,
    duration = 99 * 86400 + 23 * 3600 + 59 * 60,
    jumps = 99,
  },
  -- Table rows come from a shared engine pool. Past it rows are skipped ("No more
  -- table rows available") and the tables allocated last are dropped whole.
  enginePoolRows   = 170 - 5, -- 5 left to other windows
  legendPairs      = 6, -- two columns each, against the maxTableCols cap
  legendRows       = 5, -- reserved at the panel bottom whatever the legend holds
  -- Shared across every plotted line, not per line.
  maxTotalPoints   = 200,
  maxYRoundTo      = 1000,
  point = { type = "square", size = 5 },
  line  = { type = "normal", size = 2 },
  -- Also the cap on plotted ships: one line per distinct colour.
  seriesColors = {
    Color["graph_data_1"], Color["graph_data_2"], Color["graph_data_3"], Color["graph_data_4"],
    Color["graph_data_5"], Color["graph_data_6"], Color["graph_data_7"], Color["graph_data_8"],
  },
  isV9 = C.GetGameVersion().major >= 9,
}

local modes = {
  { id = "transactions", text = 100 },
  { id = "trades",       text = 101 },
}

local views = {
  { id = "details",      text = 102 },
  { id = "graph",        text = 103 },
  { id = "shipsbywares", text = 104 },
  { id = "waresbyships", text = 105 },
  { id = "cargoload",    text = 106 },
}

local cargoTypes = {
  { id = "all",       text = 109 },
  { id = "container", text = 1020 },
  { id = "solid",     text = 1021 },
  { id = "liquid",    text = 1022 },
  { id = "gas",       text = 1023 },
}

local function isBarView(view)
  return view == "shipsbywares" or view == "waresbyships"
end

-- Paged rather than scrolled, and the ship list gives way to them: every row it
-- draws is one the right panel cannot have.
local function isRanked(view)
  return isBarView(view) or view == "cargoload"
end

local function hasLegend(view)
  return isBarView(view) or view == "graph"
end

-- *** registration ***

local function init()
  if Helper then
    Helper.registerMenu(menu)
  end
end

function menu.cleanup()
  menu.infoFrame = nil
  menu.graph = nil
  menu.refreshQueued = nil
end

-- "back" points at the map explicitly; without a back-target Helper.closeMenu
-- falls through to the engine's generic top-level fallback.
local function onOpenMenuEvent(_, componentLuaId)
  local id64 = ConvertIDTo64Bit(componentLuaId)
  OpenMenu("ShipsTradeAnalyzerMenu", { 0, 0, id64 }, { "MapMenu", { 0, 0 }, nil })
end

-- *** state ***

local function resetState()
  menu.mode       = "transactions"
  menu.view       = "details"
  menu.filter     = sta.defaultFilter()
  menu.sortBy     = "profit"
  menu.reverse    = false
  menu.showLegend = true
  menu.barTables  = config.barTables
  menu.page       = 1
  menu.pageCount  = 1
  menu.selectedShip = nil
  menu.shipTopRow = nil
  menu.shipShift  = nil
  menu.graphShips = {}
  menu.shipColors = {}
  menu.expanded   = {}
  menu.partColors = {}
  menu.nextPartColor = 1
end

local function shipByKey(key)
  for _, ship in ipairs(sta.ships) do
    if ship.key == key then
      return ship
    end
  end
  return nil
end

-- Kept for the session, so a ware holds its colour when the ranking reshuffles.
local function colorFor(key)
  local c = menu.partColors[key]
  if c == nil then
    c = config.seriesColors[((menu.nextPartColor - 1) % #config.seriesColors) + 1]
    menu.partColors[key] = c
    menu.nextPartColor = menu.nextPartColor + 1
  end
  return c
end

-- A pool, not a sequence: a plotted ship holds its slot and the next pick takes the
-- lowest free one, so two lines cannot share a colour. Slots come back in plottedShips.
local function shipColor(key)
  local slot = menu.shipColors[key]
  if slot == nil then
    local used = {}
    for _, s in pairs(menu.shipColors) do
      used[s] = true
    end
    for i = 1, #config.seriesColors do
      if not used[i] then
        slot = i
        break
      end
    end
    menu.shipColors[key] = slot
  end
  return config.seriesColors[slot]
end

-- *** mode-agnostic data access ***

-- filteredShips walks every transaction of every ship and the frame asks for it on
-- every rebuild, so it is memoised on everything it depends on.
local function shipRows()
  local f = menu.filter
  local key = table.concat({ menu.mode, menu.sortBy, f.parentStation, f.shipClass,
    f.cargoType, tostring(f.withTransactions), tostring(sta.scanCount) }, "|")
  if menu.shipRowsKey ~= key then
    if menu.mode == "trades" then
      menu.shipRowsCache = staTrades.filteredShips(f, menu.sortBy)
    else
      menu.shipRowsCache = sta.filteredShips(f, menu.sortBy)
    end
    menu.shipRowsKey = key
  end
  return menu.shipRowsCache
end

-- The asked-for ship while the list holds it, else the list's first entry: a ship
-- the filter hides cannot be made the current row, and shipByKey searches wider.
local function listedShipOrFirst(key)
  local rows = shipRows()
  for _, entry in ipairs(rows) do
    if entry.ship.key == key then
      return key
    end
  end
  return rows[1] and rows[1].ship.key or nil
end

local function rankedRows(groupBy)
  if menu.mode == "trades" then
    return staTrades.rankedBreakdown(menu.filter, groupBy, menu.reverse)
  end
  return sta.rankedBreakdown(menu.filter, groupBy, menu.reverse)
end

local function cargoLoadRows()
  if menu.mode == "trades" then
    return staTrades.cargoLoad(menu.filter, menu.reverse)
  end
  return sta.cargoLoad(menu.filter, menu.reverse)
end

-- *** graph helpers (ported from station_ware_history) ***

-- Max-min fair allocation of a shared point budget: a line needing less than an
-- equal split keeps every point, and what it leaves over is redistributed.
local function fairShareCaps(entries, budget)
  local sorted = {}
  for _, e in ipairs(entries) do sorted[#sorted + 1] = e end
  table.sort(sorted, function(a, b) return a.need < b.need end)

  local caps = {}
  local remainingBudget = budget
  local remainingCount  = #sorted

  for i = 1, #sorted do
    local share = math.floor(remainingBudget / remainingCount)
    local entry = sorted[i]
    if entry.need <= share then
      caps[entry.id] = entry.need
      remainingBudget = remainingBudget - entry.need
      remainingCount  = remainingCount - 1
    else
      local finalShare = math.max(2, math.floor(remainingBudget / remainingCount))
      for j = i, #sorted do
        caps[sorted[j].id] = finalShare
      end
      break
    end
  end
  return caps
end

-- Keeps both extremes of every bucket, so a spike survives where fixed-interval
-- resampling would smooth it away. First and last points are kept verbatim.
local function decimatePoints(points, cap)
  if #points <= cap then
    return points
  end
  if cap <= 2 then
    return { points[1], points[#points] }
  end

  local first, last = points[1], points[#points]
  local numBuckets  = math.max(1, math.floor((cap - 2) / 2))
  local xStart, xEnd = first.x, last.x
  local bucketWidth  = (xEnd - xStart) / numBuckets

  local result    = { first }
  local lastValue = first.y
  local srcIdx    = 2

  for b = 0, numBuckets - 1 do
    local bucketEnd = (b == numBuckets - 1) and xEnd or (xStart + (b + 1) * bucketWidth)

    local minPoint, maxPoint = nil, nil
    while srcIdx < #points and points[srcIdx].x <= bucketEnd do
      local p = points[srcIdx]
      if minPoint == nil or p.y < minPoint.y then minPoint = p end
      if maxPoint == nil or p.y > maxPoint.y then maxPoint = p end
      srcIdx = srcIdx + 1
    end

    if minPoint == nil then
      result[#result + 1] = { x = bucketEnd, y = lastValue }
    elseif minPoint == maxPoint then
      result[#result + 1] = minPoint
      lastValue = minPoint.y
    elseif minPoint.x <= maxPoint.x then
      result[#result + 1] = minPoint
      result[#result + 1] = maxPoint
      lastValue = maxPoint.y
    else
      result[#result + 1] = maxPoint
      result[#result + 1] = minPoint
      lastValue = minPoint.y
    end
  end

  result[#result + 1] = last
  return result
end

-- The multiselection, falling back to the current row so the graph is never blank.
-- The only place that knows the whole drawn set, so colour slots are freed here.
local function plottedShips()
  local plotted = menu.graphShips
  if next(plotted) == nil then
    plotted = (menu.selectedShip ~= nil) and { [menu.selectedShip] = true } or {}
  end
  for key in pairs(menu.shipColors) do
    if plotted[key] == nil then
      menu.shipColors[key] = nil
    end
  end
  return plotted
end

local function graphShipList()
  local plotted = plottedShips()
  local list = {}
  for _, entry in ipairs(shipRows()) do
    if plotted[entry.ship.key] then
      list[#list + 1] = entry.ship
    end
  end
  return list
end

-- Events feeding the profit graph: a completed trade books its profit when it closed.
local function profitEvents(ship)
  local events = {}
  if menu.mode == "trades" then
    for _, trade in ipairs(staTrades.filteredTrades(ship, menu.filter)) do
      events[#events + 1] = { t = trade.endTime, value = trade.profit }
    end
    table.sort(events, function(a, b) return a.t < b.t end)
  else
    for _, tx in ipairs(sta.filteredTransactions(ship, menu.filter)) do
      events[#events + 1] = { t = tx.t, value = tx.profit }
    end
  end
  return events
end

local function buildGraphContext(ships)
  local now = sta.scanTime
  local earliest = now
  for _, ship in ipairs(ships) do
    local events = profitEvents(ship)
    if #events > 0 and events[1].t < earliest then
      earliest = events[1].t
    end
  end

  local span = math.max(60, now - earliest)
  -- Axis unit follows the span so the labels stay readable at both ends.
  local scale, unitTextId = 60, 1029
  if span > 4 * 3600 then
    scale, unitTextId = 3600, 1030
  end
  return { now = now, span = span, scale = scale, unitTextId = unitTextId, xRange = span / scale }
end

local function buildCumulativePoints(ship, ctx)
  local events = profitEvents(ship)
  local points = {}
  local total = 0
  if #events == 0 then
    return points
  end
  -- Anchor at zero before the first event, or the line starts in mid-air.
  points[1] = { x = (events[1].t - ctx.now) / ctx.scale, y = 0 }
  for _, e in ipairs(events) do
    total = total + e.value
    points[#points + 1] = { x = (e.t - ctx.now) / ctx.scale, y = total }
  end
  points[#points + 1] = { x = 0, y = total }
  return points
end

-- *** callbacks ***

function menu.onShowMenu()
  if menu.mode == nil then
    resetState()
  end

  -- A rescan renumbers the trades the expand keys index into.
  if sta.ensureScanned() then
    menu.expanded = {}
    menu.page = 1
  end

  -- Opened on an object: a ship preselects itself, a station its filter entry.
  local id64 = menu.param[3]
  if id64 ~= nil and id64 ~= 0 then
    local luaId = ConvertStringToLuaID(tostring(id64))
    -- Rebuilt through ConvertIDTo64Bit: the event's own parameter need not
    -- stringify the way a stored key does.
    local key = tostring(ConvertIDTo64Bit(luaId))
    sta.traceLog("onShowMenu: opened on %s, key %s, station %s, known ship %s.",
      GetComponentData(luaId, "idcode") or "?", key,
      tostring(IsComponentClass(luaId, "station")), tostring(shipByKey(key) ~= nil))
    if IsComponentClass(luaId, "station") then
      menu.filter.parentStation = key
      -- A station whose ships never traded: show them rather than an empty list
      -- under a filter value the dropdown does not even offer.
      if not sta.stationOffered(menu.filter, key) then
        menu.filter.withTransactions = false
      end
    elseif shipByKey(key) ~= nil then
      menu.selectedShip = listedShipOrFirst(key)
      -- Reopened on another ship, so the previous visit's scroll and picks go.
      menu.graphShips = {}
      menu.shipTopRow = nil
      menu.shipShift  = nil
    end
  end

  menu.createFrame()
end

-- Called on every display(), but the tables are rebuilt from scratch each refresh.
function menu.viewCreated(_layer, ...)
end

function menu.refreshInfoFrame()
  menu.createFrame()
end

-- Anything that changes what is ranked starts over at the first page.
local function refreshFromFirstPage()
  menu.page = 1
  menu.refreshInfoFrame()
end

function menu.buttonRefresh()
  sta.scan()
  -- Cached pairings belong to the previous scan.
  menu.expanded = {}
  refreshFromFirstPage()
end

function menu.selectMode(_, id)
  if id ~= menu.mode then
    menu.mode = id
    menu.expanded = {}
    refreshFromFirstPage()
  end
end

function menu.selectView(_, id)
  if id ~= menu.view then
    menu.view = id
    refreshFromFirstPage()
  end
end

function menu.selectParentStation(_, id)
  menu.filter.parentStation = id
  refreshFromFirstPage()
end

function menu.selectShipClass(_, id)
  menu.filter.shipClass = id
  refreshFromFirstPage()
end

function menu.selectCargoType(_, id)
  menu.filter.cargoType = id
  refreshFromFirstPage()
end

function menu.selectSort(_, id)
  menu.sortBy = id
  refreshFromFirstPage()
end

-- Narrowing to traders narrows the station options too, so the picked one can
-- stop being on offer.
function menu.toggleWithTransactions(checked)
  menu.filter.withTransactions = checked
  if not sta.stationOffered(menu.filter, menu.filter.parentStation) then
    menu.filter.parentStation = "any"
  end
  refreshFromFirstPage()
end

-- The legs are invented as the log is read, so the flag re-reads it.
function menu.toggleInjectInternal(checked)
  sta.injectInternal = checked
  menu.buttonRefresh()
end

function menu.toggleReverse(checked)
  menu.reverse = checked
  refreshFromFirstPage()
end

function menu.toggleLegend(checked)
  menu.showLegend = checked
  refreshFromFirstPage()
end

-- The slider fires on every step, so only the confirmed value rebuilds the frame.
function menu.setBarTables(value)
  menu.barTables = math.max(1, math.min(config.barTablesMax, math.floor(value)))
end

function menu.setPage(page)
  menu.page = math.max(1, math.min(menu.pageCount, math.floor(page)))
  menu.refreshInfoFrame()
end

-- A rebuild puts the box back to "current / total" without needing SetEditBoxText.
function menu.editPage(text)
  local page = tonumber(text)
  if page ~= nil then
    return menu.setPage(page)
  end
  menu.refreshInfoFrame()
end

-- The multiselection capped at the colour pool. Returns whether the plotted set
-- changed, and whether a pick was refused without being pushed back.
local function updateGraphShips(uitable, currentRow, pushBack)
  local rows = GetSelectedRows(uitable) or {}
  local map  = (menu.rowDataMap and menu.rowDataMap[uitable]) or {}

  local picks = {}
  for _, r in ipairs(rows) do
    local rowdata = map[r]
    if (type(rowdata) == "table") and (rowdata[1] == "ship") then
      picks[#picks + 1] = { row = r, key = rowdata[2] }
    end
  end

  -- Plotted ships claim their slots first, then new picks take what is left.
  local plotted, free = {}, #config.seriesColors
  for _, p in ipairs(picks) do
    if menu.graphShips[p.key] then
      plotted[p.key] = true
      free = free - 1
    end
  end
  for _, p in ipairs(picks) do
    if (not plotted[p.key]) and (free > 0) then
      plotted[p.key] = true
      free = free - 1
    end
  end

  -- A refusal changes nothing, so no rebuild clears the widget's own highlight.
  -- SetSelectedRows with an unchanged current row raises no event of its own.
  local keptRows, refused = {}, false
  for _, p in ipairs(picks) do
    if plotted[p.key] then
      keptRows[#keptRows + 1] = p.row
    else
      refused = true
    end
  end
  if refused and pushBack then
    SetSelectedRows(uitable, keptRows, currentRow)
    sta.traceLog("updateGraphShips: %d colour(s) all taken, pick on row %s refused.",
      #keptRows, tostring(currentRow))
  end

  local changed = false
  for key in pairs(plotted) do
    changed = changed or (menu.graphShips[key] == nil)
  end
  for key in pairs(menu.graphShips) do
    changed = changed or (plotted[key] == nil)
  end
  menu.graphShips = plotted
  return changed, (refused and not pushBack)
end

-- Only a real change queues a rebuild: a multiselect table reports its current row
-- again on every redraw of its own.
function menu.onRowChanged(row, rowdata, uitable, _modified, _input, source)
  if (type(rowdata) ~= "table") or (rowdata[1] ~= "ship") then
    return
  end

  -- Kept so the rebuilt list opens where the player left it.
  menu.shipTopRow = GetTopRow(uitable)

  local key     = rowdata[2]
  local changed = (key ~= menu.selectedShip)
  menu.selectedShip = key
  if changed then
    menu.page = 1
  end

  if menu.view == "graph" then
    -- "auto" is the engine picking a row while it still builds the table; writing
    -- back into it there is what the queued rebuild avoids.
    local picked, refused = updateGraphShips(uitable, row, source ~= "auto")
    changed = picked or refused or changed
    -- After the pick: refusing one moves the widget's own shift anchors.
    menu.shipShift = GetShiftStartEndRow(uitable)
  end

  if changed then
    local plotted = 0
    for _ in pairs(menu.graphShips) do plotted = plotted + 1 end
    sta.traceLog("selection: current %s, %d plotted, top row %s, source %s.",
      key, plotted, tostring(menu.shipTopRow), tostring(source))
    -- Never rebuilt here: the engine raises this from inside its own frame setup,
    -- and clearDataForRefresh would destroy the frame being built.
    menu.refreshQueued = true
  end
end

function menu.toggleExpanded(key)
  menu.expanded[key] = (not menu.expanded[key]) or nil
  menu.refreshInfoFrame()
end

-- *** frame ***

-- menu_map's own infoTableWidth is not reachable from here, so it is recomputed.
local function mapInfoTableWidth()
  local playerInfo = Helper.playerInfoConfig
  return math.max(playerInfo.width - Helper.scaleX(Helper.sidebarWidth) - (config.isV9 and Helper.minorPanelSpacing or 2 * Helper.borderSize),
    config.mapInfoMinWidth)
end

function menu.createFrame()
  Helper.clearDataForRefresh(menu, config.infoLayer)

  menu.infoFrame = Helper.createFrameHandle(menu, {
    layer           = config.infoLayer,
    standardButtons = { back = true, close = true, help = false },
    width           = Helper.viewWidth,
    height          = Helper.viewHeight,
    x               = 0,
    y               = 0,
  })
  menu.infoFrame:setBackground("solid", { color = Color["frame_background_semitransparent"] })

  local usableWidth = Helper.viewWidth - 2 * Helper.frameBorder
  local leftWidth   = Helper.round(mapInfoTableWidth() * config.leftPanelShare)
  local rightX      = Helper.frameBorder + leftWidth + Helper.borderSize
  local rightWidth  = usableWidth - leftWidth - Helper.borderSize

  -- The bar views and Cargo Load size their name column off this, not their own panel.
  menu.leftPanelWidth = leftWidth

  menu.createLeftPanel(Helper.frameBorder, leftWidth)
  menu.createRightPanel(rightX, rightWidth)

  menu.infoFrame:display()
  menu.lastRefreshTime = getElapsedTime()
end

local function dropdownOptions(entries, currentId)
  local options = {}
  for _, entry in ipairs(entries) do
    options[#options + 1] = {
      id = entry.id, icon = "", text = entry.text, displayremoveoption = false,
    }
  end
  return options, currentId
end

-- *** paged layout ***

-- One text row plus its border. The left panel measures the real pitch off its own
-- rows; this is the fallback, computed the way helper.lua computes a cell height.
local function rowPitch()
  if menu.measuredPitch ~= nil then
    return menu.measuredPitch
  end
  local height = Helper.scaleY(Helper.standardTextHeight)
  local ok, textHeight = pcall(function()
    local fontsize = Helper.scaleFont(Helper.standardFont, Helper.standardFontSize)
    return math.ceil(C.GetTextHeight("Ag", Helper.standardFont, math.floor(fontsize), 0))
  end)
  if ok and type(textHeight) == "number" then
    local scaled = Helper.scaleY(Helper.standardTextOffsety) + textHeight
    if scaled > height then
      height = scaled
    end
  end
  return height + Helper.borderSize
end

-- Padding is the text cell's own offset on either side. setColWidth only takes
-- effect before the first addRow.
local function setTextColWidth(t, col, ...)
  local fontsize = Helper.scaleFont(Helper.standardFont, Helper.standardFontSize)
  local widest   = 0.0
  for _, text in ipairs({ ... }) do
    local ok, width = pcall(function()
      return C.GetTextWidth(text, Helper.standardFont, fontsize)
    end)
    if not ok or type(width) ~= "number" then
      return
    end
    widest = math.max(widest, width)
  end
  t:setColWidth(col, math.ceil(widest) + 2 * Helper.scaleX(Helper.standardTextOffsetx), false)
end

-- Widest string a time column can hold, in each of the two shapes.
local function durationSample()
  return sta.formatDuration(config.widthSample.duration)
end

local function agoSample()
  return sta.formatAgo(0, config.widthSample.duration)
end

-- Name and sector in one cell: only the icon widget takes a second text. Each is
-- coloured by its own owner, which a station and its sector need not share.
local function createStationCell(cell, info)
  local iconSize   = Helper.standardTextHeight
  local ownerColor = sta.factionColor(info.owner)

  local iconId, iconColor = "solid", Color["icon_transparent"]
  if info.icon ~= nil and info.icon ~= "" then
    iconId    = info.icon
    iconColor = ownerColor or Color["icon_normal"]
  end

  return cell:createIcon(iconId, { width = iconSize, height = iconSize, color = iconColor })
      :setText(info.name, { halign = "left", x = iconSize + Helper.standardTextOffsetx, color = ownerColor })
      :setText2(info.sector, { halign = "right", color = sta.factionColor(info.sectorOwner) })
end

-- Same layout on a transparent icon, so both labels sit over their values.
local function createStationHeader(cell)
  local iconSize = Helper.standardTextHeight
  return cell:createIcon("solid", { width = iconSize, height = iconSize, color = Color["icon_transparent"] })
      :setText(ReadText(PAGE, 117), { halign = "left", x = iconSize + Helper.standardTextOffsetx })
      :setText2(ReadText(PAGE, 118), { halign = "right" })
end

local function pagerHeight()
  return Helper.scaleY(Helper.standardButtonHeight) + Helper.borderSize
end

-- legendRows are reserved whatever the legend holds, so the rows above it do not
-- change from page to page. The legend itself is only as tall as it needs to be.
local function legendHeights(entryCount)
  if not menu.showLegend then
    return 0, 0
  end
  local pitch    = rowPitch()
  local rows     = math.max(1, math.ceil(entryCount / config.legendPairs))
  local reserved = config.legendRows * pitch - Helper.borderSize
  return reserved, math.min(rows, config.legendRows) * pitch - Helper.borderSize
end

-- What it costs the row pool: the rows it shows, not the rows it holds - the ones
-- scrolled out of its box are never drawn.
local function legendRowCount(entryCount)
  if not menu.showLegend then
    return 0
  end
  return math.min(math.ceil(entryCount / config.legendPairs), config.legendRows)
end

local function panelBottom()
  return Helper.viewHeight - Helper.frameBorder
end

-- A table scrolls only once told how tall it may grow. Left at the default 0,
-- getMaxVisibleHeight asks for more than the frame leaves free and the engine
-- rejects the table outright ("Vertical space left doesn't suffice").
local function scrollHeight(y, bottom)
  return (bottom or panelBottom()) - y
end

-- Bottom edge left to the tables above the legend.
local function contentBottom(legendEntryCount)
  local reserved = legendHeights(legendEntryCount)
  if reserved <= 0 then
    return panelBottom()
  end
  return panelBottom() - reserved - Helper.borderSize
end

-- On a first draw the engine keeps its last row back for the mouse-over limbo row.
local function poolBudget()
  return config.enginePoolRows - 1
end

-- The pager always sits below a per-ship table.
local function detailBottom()
  return panelBottom() - pagerHeight() - Helper.borderSize
end

-- The slice of the current page. A row costs engine calls whether it is drawn or
-- not, so a page holds exactly what fits and never scrolls.
local function detailPage(itemCount, headerHeight)
  local pitch   = rowPitch()
  -- getFullHeight puts no border below its last row, so the header owes one.
  local budget  = detailBottom() - Helper.frameBorder - headerHeight - Helper.borderSize
  local perPage = math.max(1, math.floor(budget / pitch))

  menu.pageCount = math.max(1, math.ceil(itemCount / perPage))
  menu.page      = math.max(1, math.min(menu.pageCount, menu.page or 1))
  sta.traceLog("detailPage: pitch %d, budget %d, %d row(s)/page, %d item(s), page %d/%d.",
    pitch, budget, perPage, itemCount, menu.page, menu.pageCount)
  return (menu.page - 1) * perPage + 1, math.min(itemCount, menu.page * perPage)
end

-- The slice of the current page, against the vertical space and the frame's row
-- pool: every side-by-side table spends a row of it per item. The pager is always
-- drawn, or the row count would depend on the page.
local function pageLayout(itemCount, top, bottom, headerHeight, numTables, legendRows)
  local pitch   = rowPitch()
  local budget  = bottom - top - headerHeight - pagerHeight() - Helper.borderSize
  local perPage = math.max(1, math.floor(budget / pitch))

  -- Off the top: the panel title's table and the pager, one row each.
  local free   = poolBudget() - (menu.leftRowCount or 0) - 2 - legendRows
  local rowCap = math.max(1, math.floor(free / numTables))
  if rowCap < perPage then
    perPage = rowCap
  end

  menu.pageCount = math.max(1, math.ceil(itemCount / perPage))
  menu.page      = math.max(1, math.min(menu.pageCount, menu.page or 1))
  sta.traceLog("pageLayout: pitch %d, budget %d, row cap %d, %d row(s)/page, %d item(s), page %d/%d.",
    pitch, budget, rowCap, perPage, itemCount, menu.page, menu.pageCount)
  return {
    first = (menu.page - 1) * perPage + 1,
    last  = math.min(itemCount, menu.page * perPage),
  }
end

-- Vanilla's transaction-log navigator: first / previous / editable "page / total"
-- / next / last.
local function createPager(x, width, bottom, tabOrder)
  local buttonWidth = Helper.scaleY(Helper.standardButtonHeight)
  local pagesWidth  = Helper.scaleX(4 * Helper.standardTextHeight)
  local ok, textWidth = pcall(function()
    return C.GetTextWidth(" 9999 / 9999 ", Helper.standardFont,
      Helper.scaleFont(Helper.standardFont, Helper.standardFontSize))
  end)
  if ok and type(textWidth) == "number" then
    pagesWidth = math.ceil(textWidth) + Helper.scaleX(Helper.standardTextOffsetx)
  end
  local tableWidth = 4 * buttonWidth + pagesWidth + 4 * Helper.borderSize

  local t = menu.infoFrame:addTable(5, {
    tabOrder = tabOrder, width = tableWidth,
    x = x + math.max(0, math.floor((width - tableWidth) / 2)),
    y = bottom - Helper.scaleY(Helper.standardButtonHeight),
    -- No variable column left to take the reserved space, which helper.lua logs over.
    reserveScrollBar = false,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  t:setColWidth(1, buttonWidth, false)
  t:setColWidth(2, buttonWidth, false)
  t:setColWidth(3, pagesWidth, false)
  t:setColWidth(4, buttonWidth, false)
  t:setColWidth(5, buttonWidth, false)

  -- Interactive widgets need a selectable row, or the whole view is rejected.
  local row = t:addRow(true, { fixed = true })
  local hasPrev, hasNext = menu.page > 1, menu.page < menu.pageCount
  row[1]:createButton({ active = hasPrev, cellBGColor = Color["row_background"] }):setIcon("widget_arrow_skip_left_01")
  row[1].handlers.onClick = function() return menu.setPage(1) end
  row[2]:createButton({ active = hasPrev, cellBGColor = Color["row_background"] }):setIcon("widget_arrow_left_01")
  row[2].handlers.onClick = function() return menu.setPage(menu.page - 1) end
  local editBoxProperties = {
    active = menu.pageCount > 1, description = ReadText(PAGE, 1013),
    height = Helper.standardButtonHeight,
  }
  row[3]:createEditBox(editBoxProperties):setText(menu.page .. " / " .. menu.pageCount, { halign = "center" })
  row[3].handlers.onEditBoxDeactivated = function(_, text) return menu.editPage(text) end
  row[4]:createButton({ active = hasNext, cellBGColor = Color["row_background"] }):setIcon("widget_arrow_right_01")
  row[4].handlers.onClick = function() return menu.setPage(menu.page + 1) end
  row[5]:createButton({ active = hasNext, cellBGColor = Color["row_background"] }):setIcon("widget_arrow_skip_right_01")
  row[5].handlers.onClick = function() return menu.setPage(menu.pageCount) end
end

-- Lists the whole ranking, not the current page, so an entry keeps its place while
-- paging. Rows are selectable, or the table cannot take focus and never scrolls.
local function createLegend(x, width, entries, tabOrder, colorOf)
  local _, visible = legendHeights(#entries)
  if visible <= 0 then
    return
  end
  local legend = menu.infoFrame:addTable(config.legendPairs * 2, {
    tabOrder = tabOrder, width = width, x = x,
    y = panelBottom() - visible,
    maxVisibleHeight = visible,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  for i = 1, config.legendPairs do
    legend:setColWidth(i * 2 - 1, Helper.standardTextHeight)
  end
  for i = 1, #entries, config.legendPairs do
    local legendRow = legend:addRow(true, {})
    for j = 0, config.legendPairs - 1 do
      local entry = entries[i + j]
      if entry ~= nil then
        legendRow[j * 2 + 1]:createText("")
        legendRow[j * 2 + 1].properties.cellBGColor = colorOf(entry.key)
        legendRow[j * 2 + 2]:createText(entry.name, { halign = "left" })
      end
    end
  end
end

-- A checkbox without an explicit width stretches over the cell, and there is no
-- halign for non-text widgets, so it is squared and centred by hand.
local function createCenteredCheckBox(cell, checked)
  local size = Helper.scaleX(Helper.standardTextHeight)
  cell:createCheckBox(checked, { width = size, height = size, scaling = false })
  cell.properties.x = math.max(0, math.floor((cell:getColSpanWidth() - size) / 2))
  return cell
end

function menu.createLeftPanel(x, width)
  -- Only the graph draws several ships, so only it needs the multiselection.
  local multi = (menu.view == "graph")

  -- Four columns for both halves: a control is a label in 1 and the widget over
  -- 2-4, a ship row is the name over 1-3 and its profit in 4.
  local leftTable = menu.infoFrame:addTable(4, {
    tabOrder = 1, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    maxVisibleHeight = scrollHeight(Helper.frameBorder), multiSelect = multi,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  local row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(4):createText(ReadText(PAGE, 1000), Helper.titleTextProperties)

  -- View
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1002), { halign = "left" })
  local viewEntries = {}
  for _, v in ipairs(views) do
    viewEntries[#viewEntries + 1] = { id = v.id, text = ReadText(PAGE, v.text) }
  end
  row[2]:setColSpan(3):createDropDown(dropdownOptions(viewEntries), { startOption = menu.view, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectView

  -- Analysis mode
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1001), { halign = "left" })
  local modeEntries = {}
  for _, m in ipairs(modes) do
    modeEntries[#modeEntries + 1] = { id = m.id, text = ReadText(PAGE, m.text) }
  end
  row[2]:setColSpan(3):createDropDown(dropdownOptions(modeEntries), { startOption = menu.mode, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectMode

  -- Not a filter: it changes what the log is read as, so it sits above them.
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1035), { halign = "left" })
  createCenteredCheckBox(row[2]:setColSpan(3), sta.injectInternal)
  row[2].handlers.onClick = function(_, checked) return menu.toggleInjectInternal(checked) end

  -- Filters
  row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(4):createText(ReadText(PAGE, 121), Helper.titleTextProperties)

  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1033), { halign = "left" })
  createCenteredCheckBox(row[2]:setColSpan(3), menu.filter.withTransactions)
  row[2].handlers.onClick = function(_, checked) return menu.toggleWithTransactions(checked) end

  local stationEntries = {
    { id = "any",  text = ReadText(PAGE, 107) },
    { id = "none", text = ReadText(PAGE, 108) },
  }
  for _, station in ipairs(sta.stationOptions(menu.filter)) do
    stationEntries[#stationEntries + 1] = { id = station.key, text = station.name }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1003), { halign = "left" })
  row[2]:setColSpan(3):createDropDown(dropdownOptions(stationEntries), { startOption = menu.filter.parentStation, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectParentStation

  local classEntries = { { id = "all", text = ReadText(PAGE, 109) } }
  for _, classId in ipairs(sta.shipClasses) do
    classEntries[#classEntries + 1] = { id = classId, text = sta.classLetter(classId) }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1004), { halign = "left" })
  row[2]:setColSpan(3):createDropDown(dropdownOptions(classEntries), { startOption = menu.filter.shipClass, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectShipClass

  local cargoEntries = {}
  for _, c in ipairs(cargoTypes) do
    cargoEntries[#cargoEntries + 1] = { id = c.id, text = ReadText(PAGE, c.text) }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1005), { halign = "left" })
  row[2]:setColSpan(3):createDropDown(dropdownOptions(cargoEntries), { startOption = menu.filter.cargoType, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectCargoType

  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1007), { halign = "left" })
  local sortEntries = {
    { id = "profit", text = ReadText(PAGE, 1009) },
    { id = "name",   text = ReadText(PAGE, 1008) },
  }
  row[2]:setColSpan(3):createDropDown(dropdownOptions(sortEntries), { startOption = menu.sortBy, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectSort

  if isRanked(menu.view) then
    row = leftTable:addRow(true, { fixed = true })
    row[1]:createText(ReadText(PAGE, 1011), { halign = "left" })
    createCenteredCheckBox(row[2]:setColSpan(3), menu.reverse)
    row[2].handlers.onClick = function(_, checked) return menu.toggleReverse(checked) end
  end

  -- Both buy rows for the right panel: the legend gives up its reserved band, the
  -- slider puts fewer tables side by side.
  if hasLegend(menu.view) then
    row = leftTable:addRow(true, { fixed = true })
    row[1]:createText(ReadText(PAGE, 1010), { halign = "left" })
    createCenteredCheckBox(row[2]:setColSpan(3), menu.showLegend)
    row[2].handlers.onClick = function(_, checked) return menu.toggleLegend(checked) end
  end

  if isBarView(menu.view) then
    row = leftTable:addRow(true, { fixed = true })
    row[1]:createText(ReadText(PAGE, 1031), { halign = "left" })
    row[2]:setColSpan(3):createSliderCell({
      height = Helper.standardButtonHeight,
      min = 1, max = config.barTablesMax, start = menu.barTables, step = 1,
    })
    row[2].handlers.onSliderCellChanged = function(_, value) return menu.setBarTables(value) end
    row[2].handlers.onSliderCellConfirm = function() return refreshFromFirstPage() end
  end

  row = leftTable:addRow(true, { fixed = true })
  row[1]:setColSpan(4):createButton({}):setText(ReadText(PAGE, 1012), { halign = "center" })
  row[1].handlers.onClick = function() return menu.buttonRefresh() end

  -- Ship list
  local rows = shipRows()
  local totalProfit = 0
  for _, entry in ipairs(rows) do
    totalProfit = totalProfit + entry.profit
  end

  row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(3):createText(ReadText(PAGE, 122), Helper.titleTextProperties)
  row[4]:createText(sta.formatMoney(totalProfit), {
    halign = "right", color = (totalProfit >= 0) and Color["text_positive"] or Color["text_negative"],
  })

  if #rows == 0 then
    row = leftTable:addRow(false, {})
    row[1]:setColSpan(4):createText(sta.scanned and ReadText(PAGE, 1016) or ReadText(PAGE, 1015),
      { halign = "center", wordwrap = true, color = Color["text_inactive"] })
    menu.leftRowCount = #leftTable.rows
    return
  end

  -- Height of the control block the ship rows have to fit under. Measured over the
  -- control rows alone: getFullHeight prices every cell with a GetTextHeight call.
  local beforeShips = leftTable:getFullHeight()

  -- The paged views need every row the pool can spare, so the list gives way to its
  -- own count there - one plain text row, which is also the pitch probe.
  if isRanked(menu.view) then
    row = leftTable:addRow(false, {})
    row[1]:setColSpan(3):createText(ReadText(PAGE, 1032), { halign = "left" })
    row[4]:createText(tostring(#rows), { halign = "right" })
    menu.measuredPitch = row:getHeight() + Helper.borderSize
    menu.leftRowCount  = #leftTable.rows
    sta.traceLog("rowPitch: measured %d over 1 count row, %d left panel row(s).",
      menu.measuredPitch, menu.leftRowCount)
    return
  end

  -- A ship is picked by making its row current, so the rows carry their id as row
  -- data and no cell carries a click handler.
  local selectedRow
  local firstShipRow
  local plottedSet = multi and plottedShips() or {}
  for _, entry in ipairs(rows) do
    local key     = entry.ship.key
    local plotted = plottedSet[key] ~= nil
    row = leftTable:addRow({ "ship", key }, { multiSelected = plotted })
    firstShipRow = firstShipRow or row
    if key == menu.selectedShip then
      selectedRow = row.index
    end
    -- A plotted row takes its line's colour; the inline icon follows the cell.
    local icon = (entry.ship.icon ~= "") and ("\027[" .. entry.ship.icon .. "] ") or ""
    row[1]:setColSpan(3):createText(icon .. entry.ship.fullName,
      { halign = "left", color = plotted and shipColor(key) or nil })
    row[4]:createText(sta.formatMoney(entry.profit), {
      halign = "right", color = (entry.profit >= 0) and Color["text_positive"] or Color["text_negative"],
    })
  end

  -- Every ship row is the same plain text, so one of them is the pitch.
  menu.measuredPitch = firstShipRow:getHeight() + Helper.borderSize
  -- What the right panel has left of the frame's row pool.
  menu.leftRowCount  = #leftTable.rows
  sta.traceLog("rowPitch: measured %d over %d ship row(s), %d left panel row(s).",
    menu.measuredPitch, #rows, menu.leftRowCount)

  -- Put the list back where the player left it, shift range included.
  if selectedRow ~= nil then
    leftTable:setSelectedRow(selectedRow)
    -- The engine never moves the top row to the selection, so a first build opened
    -- on a ship far down the list would hide it.
    if menu.shipTopRow == nil then
      local visible   = math.max(1, math.floor((scrollHeight(Helper.frameBorder) - beforeShips) / menu.measuredPitch))
      local firstShip = #leftTable.rows - #rows + 1
      if (selectedRow - firstShip + 1) > visible then
        menu.shipTopRow = selectedRow - visible + 1
      end
    end
  end
  if menu.shipTopRow ~= nil then
    leftTable:setTopRow(menu.shipTopRow)
  end
  if multi and (menu.shipShift ~= nil) then
    leftTable:setShiftStartEnd(menu.shipShift[1], menu.shipShift[2])
  end
end

function menu.createRightPanel(x, width)
  if menu.view == "graph" then
    menu.createGraphPanel(x, width)
  elseif menu.view == "shipsbywares" then
    menu.createRankedPanel(x, width, "ship")
  elseif menu.view == "waresbyships" then
    menu.createRankedPanel(x, width, "ware")
  elseif menu.view == "cargoload" then
    menu.createCargoLoadPanel(x, width)
  elseif menu.mode == "trades" then
    menu.createTradesPanel(x, width)
  else
    menu.createTransactionsPanel(x, width)
  end
end

local function emptyPanel(x, width, textId)
  local t = menu.infoFrame:addTable(1, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder,
    maxVisibleHeight = scrollHeight(Helper.frameBorder),
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  local row = t:addRow(false, { fixed = true })
  row[1]:createText(ReadText(PAGE, textId), { halign = "center", wordwrap = true, color = Color["text_inactive"] })
end

function menu.createTransactionsPanel(x, width)
  local ship = menu.selectedShip and shipByKey(menu.selectedShip) or nil
  if ship == nil then
    return emptyPanel(x, width, 1017)
  end

  local transactions = sta.filteredTransactions(ship, menu.filter)
  if #transactions == 0 then
    return emptyPanel(x, width, 1016)
  end

  -- Station and sector share one column, the way an expanded trade shows them.
  local t = menu.infoFrame:addTable(10, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    maxVisibleHeight = scrollHeight(Helper.frameBorder, detailBottom()),
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  -- Bounded columns fixed, remainder to the station cell.
  setTextColWidth(t, 1, ReadText(PAGE, 110), agoSample())
  setTextColWidth(t, 2, ReadText(PAGE, 111), ReadText(PAGE, 1018), ReadText(PAGE, 1019))
  if sta.widestWareName ~= "" then
    setTextColWidth(t, 3, ReadText(PAGE, 112), sta.widestWareName)
  end
  setTextColWidth(t, 5, ReadText(PAGE, 113), sta.formatPrice(config.widthSample.price))
  setTextColWidth(t, 6, ReadText(PAGE, 114), tostring(config.widthSample.quantity))
  setTextColWidth(t, 7, ReadText(PAGE, 115), sta.formatMoney(config.widthSample.total))
  setTextColWidth(t, 8, ReadText(PAGE, 116), sta.formatMoney(config.widthSample.total))
  setTextColWidth(t, 9, ReadText(PAGE, 134), tostring(config.widthSample.jumps))
  setTextColWidth(t, 10, ReadText(PAGE, 119), string.format("%.0f%%", config.widthSample.load))

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(10):createText(ship.fullName, Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[1]:createText(ReadText(PAGE, 110), { halign = "right" })
  row[2]:createText(ReadText(PAGE, 111), { halign = "center" })
  row[3]:createText(ReadText(PAGE, 112), { halign = "left" })
  createStationHeader(row[4])
  row[5]:createText(ReadText(PAGE, 113), { halign = "right" })
  row[6]:createText(ReadText(PAGE, 114), { halign = "right" })
  row[7]:createText(ReadText(PAGE, 115), { halign = "right" })
  row[8]:createText(ReadText(PAGE, 116), { halign = "right" })
  row[9]:createText(ReadText(PAGE, 134), { halign = "right" })
  row[10]:createText(ReadText(PAGE, 119), { halign = "right" })

  -- Measured, not derived: the title row is taller than the header below it.
  local first, last = detailPage(#transactions, t:getFullHeight())

  -- Newest first, so the first page is the recent tail.
  for j = first, last do
    local tx = transactions[#transactions - j + 1]
    row = t:addRow(true, {})
    row[1]:createText(sta.formatAgo(tx.t), { halign = "right" })
    row[2]:createText(ReadText(PAGE, tx.sale and 1019 or 1018),
      { halign = "center", color = tx.sale and Color["text_positive"] or Color["text_negative"] })
    row[3]:createText(sta.getWare(tx.ware).name, { halign = "left" })
    createStationCell(row[4], {
      name = tx.pName, sector = tx.pSector, owner = tx.pOwner,
      sectorOwner = tx.pSecOwner, icon = tx.pIcon,
    })
    row[5]:createText(sta.formatPrice(tx.price), { halign = "right" })
    row[6]:createText(tostring(tx.vol), { halign = "right" })
    row[7]:createText(sta.formatMoney(tx.sale and tx.sum or -tx.sum),
      { halign = "right", color = tx.sale and Color["text_positive"] or Color["text_negative"] })
    row[8]:createText(sta.formatMoney(tx.profit),
      { halign = "right", color = (tx.profit >= 0) and Color["text_positive"] or Color["text_negative"] })
    -- Filled by the scan; a dash when a sector is unknown, never a zero.
    row[9]:createText(tx.jumps and tostring(tx.jumps) or "-", { halign = "right" })
    row[10]:createText(string.format("%.0f%%", tx.load), { halign = "right" })
  end

  createPager(x, width, panelBottom(), 3)
end

function menu.createTradesPanel(x, width)
  local ship = menu.selectedShip and shipByKey(menu.selectedShip) or nil
  if ship == nil then
    return emptyPanel(x, width, 1017)
  end

  local trades = staTrades.filteredTrades(ship, menu.filter)
  if #trades == 0 then
    return emptyPanel(x, width, 1016)
  end

  local t = menu.infoFrame:addTable(9, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    maxVisibleHeight = scrollHeight(Helper.frameBorder, detailBottom()),
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  -- Expand column, vanilla's own: a button as tall as a text row, so a trade row
  -- cannot outgrow the pitch the page is measured against.
  t:setColWidth(1, Helper.scaleY(Helper.standardTextHeight) + Helper.standardContainerOffset, false)

  -- Columns 4-6 also carry a leg row's operation, volume and price.
  setTextColWidth(t, 2, ReadText(PAGE, 110), agoSample())
  setTextColWidth(t, 4, ReadText(PAGE, 130), sta.formatMoney(config.widthSample.total),
    ReadText(PAGE, 1018), ReadText(PAGE, 1019))
  setTextColWidth(t, 5, ReadText(PAGE, 131), sta.formatMoney(config.widthSample.total),
    tostring(config.widthSample.quantity))
  setTextColWidth(t, 6, ReadText(PAGE, 132), sta.formatMoney(config.widthSample.total),
    sta.formatPrice(config.widthSample.price))
  setTextColWidth(t, 7, ReadText(PAGE, 133), durationSample())
  setTextColWidth(t, 8, ReadText(PAGE, 134), tostring(config.widthSample.jumps))
  setTextColWidth(t, 9, ReadText(PAGE, 119), string.format("%.0f%%", config.widthSample.load))

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(9):createText(ship.fullName, Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[2]:createText(ReadText(PAGE, 110), { halign = "right" })
  row[3]:createText(ReadText(PAGE, 112), { halign = "left" })
  row[4]:createText(ReadText(PAGE, 130), { halign = "right" })
  row[5]:createText(ReadText(PAGE, 131), { halign = "right" })
  row[6]:createText(ReadText(PAGE, 132), { halign = "right" })
  row[7]:createText(ReadText(PAGE, 133), { halign = "right" })
  row[8]:createText(ReadText(PAGE, 134), { halign = "right" })
  row[9]:createText(ReadText(PAGE, 119), { halign = "right" })

  -- Measured, not derived: the title row is taller than the header below it. The
  -- height cap stays for expanded trades, whose legs go on top of the page.
  local first, last = detailPage(#trades, t:getFullHeight())

  -- Newest first, so the first page is the recent tail.
  for j = first, last do
    local i = #trades - j + 1
    local trade = trades[i]
    local key = ship.key .. "#" .. i
    row = t:addRow("trade_" .. key, {})
    row[1]:createButton({ height = Helper.standardTextHeight }):setText(menu.expanded[key] and "-" or "+", { halign = "center" })
    row[1].handlers.onClick = function() return menu.toggleExpanded(key) end
    row[2]:createText(sta.formatAgo(trade.startTime), { halign = "right" })
    row[3]:createText(sta.getWare(trade.ware).name, { halign = "left" })
    row[4]:createText(sta.formatMoney(trade.buyCost), { halign = "right" })
    row[5]:createText(sta.formatMoney(trade.revenue), { halign = "right" })
    row[6]:createText(sta.formatMoney(trade.profit),
      { halign = "right", color = (trade.profit >= 0) and Color["text_positive"] or Color["text_negative"] })
    row[7]:createText(sta.formatDuration(trade.duration), { halign = "right" })
    -- A dash, not a zero: the graph may not be loaded, or the route unreachable.
    local jumps = staTrades.jumpsOf(trade)
    row[8]:createText(jumps and tostring(jumps) or "-", { halign = "right" })
    row[9]:createText(string.format("%.0f%%", trade.load), { halign = "right" })

    if menu.expanded[key] then
      -- A leg lines up under the trade row: station in the ware column, then
      -- operation / volume / price under the three sums.
      local function legRow(leg, isSale)
        local legrow = t:addRow(false, { bgColor = Color["row_background_unselectable"] })
        legrow[2]:createText(sta.formatAgo(leg.t), { halign = "right" })
        createStationCell(legrow[3], {
          name = leg.station, sector = leg.sector, owner = leg.owner,
          sectorOwner = leg.sectorOwner, icon = leg.icon,
        })
        legrow[4]:createText(ReadText(PAGE, isSale and 1019 or 1018),
          { halign = "center", color = isSale and Color["text_positive"] or Color["text_negative"] })
        legrow[5]:createText(tostring(leg.vol), { halign = "right" })
        legrow[6]:createText(sta.formatPrice(leg.price), { halign = "right" })
      end
      for _, leg in ipairs(trade.purchases) do legRow(leg, false) end
      for _, leg in ipairs(trade.sales) do legRow(leg, true) end
    end
  end

  createPager(x, width, panelBottom(), 3)
end

function menu.createGraphPanel(x, width)
  local ships = graphShipList()
  if #ships == 0 then
    return emptyPanel(x, width, 1017)
  end

  local ctx = buildGraphContext(ships)
  local lines = {}
  for _, ship in ipairs(ships) do
    local points = buildCumulativePoints(ship, ctx)
    if #points > 0 then
      lines[#lines + 1] = { id = ship.key, ship = ship, points = points, need = #points }
    end
  end
  if #lines == 0 then
    return emptyPanel(x, width, 1016)
  end

  local totalPoints = 0
  for _, line in ipairs(lines) do
    totalPoints = totalPoints + line.need
  end
  local caps = nil
  if totalPoints > config.maxTotalPoints then
    caps = fairShareCaps(lines, config.maxTotalPoints)
    sta.traceLog("createGraphPanel: %d point(s) across %d line(s) exceeds the %d budget, downsampling.",
      totalPoints, #lines, config.maxTotalPoints)
  end

  -- The graph widget has no legend of its own, so the bottom one serves here too.
  local legendEntries = {}
  for _, line in ipairs(lines) do
    legendEntries[#legendEntries + 1] = { key = line.id, name = line.ship.fullName }
  end

  -- The cell needs an explicit height: the screen's own aspect ratio, capped at
  -- what the legend leaves above it.
  local graphHeight = math.floor(math.min(width * Helper.viewHeight / Helper.viewWidth,
    contentBottom(#legendEntries) - Helper.frameBorder))
  local t = menu.infoFrame:addTable(1, { tabOrder = 2, width = width, x = x, y = Helper.frameBorder })
  local row = t:addRow(false, { fixed = true })
  menu.graph = row[1]:createGraph({ height = graphHeight, scaling = false })
  menu.graph:setTitle(ReadText(PAGE, 103),
    { font = Helper.titleFont, fontsize = Helper.scaleFont(Helper.titleFont, Helper.titleFontSize) })

  local maxY, minY = 1, 0
  for _, line in ipairs(lines) do
    local points = line.points
    if caps ~= nil and #points > caps[line.id] then
      points = decimatePoints(points, caps[line.id])
    end
    local color = shipColor(line.id)
    local datarecord = menu.graph:addDataRecord({
      markertype = config.point.type, markersize = config.point.size, markercolor = color,
      linetype = config.line.type, linewidth = config.line.size, linecolor = color,
      mouseOverText = line.ship.fullName,
    })
    for _, p in ipairs(points) do
      datarecord:addData(p.x, p.y, nil, nil)
      maxY = math.max(maxY, p.y)
      minY = math.min(minY, p.y)
    end
  end

  maxY = math.max(config.maxYRoundTo, math.ceil(maxY / config.maxYRoundTo) * config.maxYRoundTo)
  minY = (minY < 0) and (math.floor(minY / config.maxYRoundTo) * config.maxYRoundTo) or 0

  menu.graph:setXAxis({ startvalue = -ctx.xRange, endvalue = 0,
    granularity = Helper.round(ctx.xRange / 6, 3), gridcolor = Color["graph_grid"] })
  menu.graph:setXAxisLabel(ReadText(PAGE, 110) .. " (" .. ReadText(PAGE, ctx.unitTextId) .. ")")
  menu.graph:setYAxis({ startvalue = minY, endvalue = maxY,
    granularity = (maxY - minY) / 10, gridcolor = Color["graph_grid"] })
  menu.graph:setYAxisLabel(ReadText(1001, 101))

  createLegend(x, width, legendEntries, 3, shipColor)
end

-- Stacked bars built from background-coloured cells, the table widget's only route
-- to a segmented bar. The 13-column cap is beaten by putting menu.barTables tables
-- side by side; every row exists in all of them, which keeps them aligned.
function menu.createRankedPanel(x, width, groupBy)
  local groups = rankedRows(groupBy)
  if #groups == 0 then
    return emptyPanel(x, width, 1016)
  end

  -- Over the whole ranking, not just this page: its height is what the bars fit above.
  local seen, legendEntries = {}, {}
  for _, g in ipairs(groups) do
    for _, p in ipairs(g.partOrder) do
      if not seen[p.key] then
        seen[p.key] = true
        legendEntries[#legendEntries + 1] = p
      end
    end
  end
  table.sort(legendEntries, function(a, b) return a.name < b.name end)

  -- Against the largest total of the whole ranking, so rows stay comparable per page.
  local maxTotal = 0 ---@type number
  for _, g in ipairs(groups) do
    maxTotal = math.max(maxTotal, math.abs(g.total))
  end
  if maxTotal <= 0 then
    maxTotal = 1
  end

  local numBars   = math.max(1, menu.barTables or config.barTables)
  local cols      = config.maxTableCols
  local segments  = numBars * cols
  local labelsAndTotalsWidth = menu.leftPanelWidth * config.labelAndTotalColShare
  -- Inner borders of the bar tables, the label table's own, and a gap per bar table.
  local borders   = (numBars * (cols - 1) + numBars + 1) * Helper.borderSize
  local segWidth  = math.max(1, math.floor((width - labelsAndTotalsWidth - borders) / segments))
  -- The total column takes what the segments' flooring left, so the panel ends flush.
  labelsAndTotalsWidth = math.floor(width - borders - segments * segWidth)

  local bottom = contentBottom(#legendEntries)

  -- The title gets a table of its own, so no data table carries a header row and
  -- none of them can start a row higher than its neighbour.
  local titleTable = menu.infoFrame:addTable(1, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder,
    maxVisibleHeight = scrollHeight(Helper.frameBorder, bottom),
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  local titleRow = titleTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  titleRow[1]:createText(ReadText(PAGE, (groupBy == "ware") and 105 or 104), Helper.titleTextProperties)

  local dataY = Helper.frameBorder + titleTable:getFullHeight() + Helper.borderSize

  local function addDataTable(numCols, tableWidth, tableX, tabOrder)
    return menu.infoFrame:addTable(numCols, {
      tabOrder = tabOrder, width = tableWidth, x = tableX, y = dataY, borderEnabled = true,
      -- Paging fills these to fit; the cap keeps a row-height misjudgement to one
      -- clipped row instead of a dropped table.
      maxVisibleHeight = scrollHeight(dataY, bottom),
      -- No variable column left to take the reserved space.
      reserveScrollBar = false,
      backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
    })
  end

  -- Name and total are built first: the frame hands out rows in creation order, so
  -- what the player reads is the last thing an exhausted pool takes away.
  local labelTable = addDataTable(2, labelsAndTotalsWidth + Helper.borderSize, x, 3)
  setTextColWidth(labelTable, 2, sta.formatMoney(config.widthSample.total))

  local barWidth = cols * segWidth + (cols - 1) * Helper.borderSize
  local tables, tableX = {}, x + labelTable.properties.width + Helper.borderSize
  for k = 1, numBars do
    local t = addDataTable(cols, barWidth, tableX, 3 + k)
    for col = 1, cols do
      t:setColWidth(col, segWidth, false)
    end
    tables[k] = t
    tableX = tableX + barWidth + Helper.borderSize
  end

  -- No data table carries a header, so the rows start right below the title table.
  local layout = pageLayout(#groups, dataY, bottom, 0,
    numBars + 1, legendRowCount(#legendEntries))

  for i = layout.first, layout.last do
    local g = groups[i]
    local labelRow = labelTable:addRow(false, {})
    labelRow[1]:createText(g.name, { halign = "left" })
    labelRow[2]:createText(sta.formatMoney(g.total), {
      halign = "right", color = (g.total >= 0) and Color["text_positive"] or Color["text_negative"],
    })

    local rows = {}
    for k, t in ipairs(tables) do
      rows[k] = t:addRow(false, {})
    end

    -- Segment n is the n-th cell counted across the bar tables.
    local function segmentCell(n)
      return rows[math.floor((n - 1) / cols) + 1][(n - 1) % cols + 1]
    end

    -- Bar length is the group's share of the largest total; segment widths inside
    -- it are each part's share of the group.
    local barCells = math.max(1, math.floor(math.abs(g.total) / maxTotal * segments + 0.5))
    local partsTotal = 0 ---@type number
    for _, p in ipairs(g.partOrder) do
      partsTotal = partsTotal + math.abs(p.value)
    end
    if partsTotal <= 0 then
      partsTotal = 1
    end

    local filled = 0
    for _, p in ipairs(g.partOrder) do
      if filled >= barCells then
        break
      end
      local cells = math.floor(math.abs(p.value) / partsTotal * barCells + 0.5)
      if cells < 1 and math.abs(p.value) > 0 then
        cells = 1
      end
      for _ = 1, math.min(cells, barCells - filled) do
        filled = filled + 1
        local cell = segmentCell(filled)
        -- A bare coloured cell, so the legend is its only label.
        cell:createText("", { mouseOverText = p.name })
        cell.properties.cellBGColor = colorFor(p.key)
      end
    end
  end

  -- Both budgets, measured: the height against the space, and the rows against the pool.
  local pageRows  = layout.last - layout.first + 1
  local fixedRows = (menu.leftRowCount or 0) + 2 + legendRowCount(#legendEntries)
  local frameRows = fixedRows + (numBars + 1) * pageRows
  sta.traceLog("rankedPanel: table height %d, budget %d, %d frame row(s) of %d.",
    labelTable:getFullHeight(), bottom - dataY - pagerHeight() - Helper.borderSize,
    frameRows, poolBudget())
  -- pageLayout counts against the same budget, so this means the count is off
  -- somewhere: past the pool the tables created last lose their rows silently.
  if frameRows > poolBudget() then
    sta.debugLog("rankedPanel: %d row(s) requested, pool budget is %d - rows will be skipped.",
      frameRows, poolBudget())
  end

  createPager(x, width, bottom, 4 + numBars)
  createLegend(x, width, legendEntries, 5 + numBars, colorFor)
end

-- One bar per ship, so no segments and no legend: the status bar widget draws it.
-- A single table, so it just scrolls and needs neither paging nor a height budget.
function menu.createCargoLoadPanel(x, width)
  local rows = cargoLoadRows()
  if #rows == 0 then
    return emptyPanel(x, width, 1016)
  end

  local t = menu.infoFrame:addTable(4, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    maxVisibleHeight = scrollHeight(Helper.frameBorder),
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  t:setColWidth(1, math.floor((menu.leftPanelWidth or width) * config.nameColShare), false)
  setTextColWidth(t, 3, ReadText(PAGE, 1025), sta.formatMoney(config.widthSample.load))
  setTextColWidth(t, 4, ReadText(PAGE, 1025), sta.formatMoney(config.widthSample.load))

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(4):createText(ReadText(PAGE, 106), Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[1]:createText(ReadText(PAGE, 122), { halign = "left" })
  row[2]:createText(ReadText(PAGE, 119), { halign = "left" })
  row[3]:createText(ReadText(PAGE, 1025), { halign = "right" })
  row[4]:createText(ReadText(PAGE, 1026), { halign = "right" })

  -- Selectable, or the table takes no input focus and cannot be scrolled at all.
  for i = 1, #rows do
    local entry = rows[i]
    row = t:addRow(true, {})
    row[1]:createText(entry.name, { halign = "left" })
    row[2]:createStatusBar({
      current = entry.average, start = 0, max = 100, valueColor = colorFor(entry.key),
      height = Helper.scaleY(Helper.standardTextHeight), scaling = false,
    })
    row[3]:createText(string.format("%.0f%%", entry.average), { halign = "right" })
    row[4]:createText(string.format("%.0f%%", entry.best), { halign = "right" })
  end
end

-- *** standard menu callbacks ***

function menu.onUpdate()
  -- Drained here, not where it was raised: onRowChanged runs inside the engine's
  -- own frame setup, which must not be torn down under it.
  if menu.refreshQueued then
    menu.refreshQueued = nil
    return menu.createFrame()
  end
  if menu.infoFrame then
    menu.infoFrame:update()
  end
end

function menu.onCloseElement(dueToClose)
  Helper.closeMenu(menu, dueToClose)
  menu.cleanup()
end

-- State is left unset: onShowMenu builds it on first open, by which point MD has
-- populated the config blackboard the filter defaults come from.
local function Init()
  init()
  RegisterEvent("ShipsTradeAnalyzer.OpenMenu", onOpenMenuEvent)
end

Register_OnLoad_Init(Init)
