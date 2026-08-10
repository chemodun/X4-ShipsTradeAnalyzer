-- Ships Trade Analyzer - menu.
--
-- Standalone top-level menu registered the way vanilla registers
-- TransactionLogMenu. Left panel: analysis mode, view, filters and the ship
-- list. Right panel: whichever view is selected.
--
-- Opened from the right-click interaction menu of any player-owned ship or
-- station (raise_lua_event 'ShipsTradeAnalyzer.OpenMenu' param=<component>).
--
-- The X4 graph widget only draws lines (graphtype is "line" and nothing else
-- is accepted), so the ware and load breakdowns are horizontal bars built from
-- background-coloured table cells rather than real column charts.

local sta       = require("extensions.ships_trade_analyzer.ui.sta_data")
local staTrades = require("extensions.ships_trade_analyzer.ui.sta_trades")

local PAGE = 1972092439

local menu = {
  name            = "ShipsTradeAnalyzerMenu",
  lastRefreshTime = 0,
  updateInterval  = 0.1,
}

local config = {
  infoLayer      = 4,
  leftPanelShare = 0.34,
  -- A table cannot have more than 13 columns, so the bar of the ranked views is
  -- spread over this many tables side by side: barTables * 13 - 2 segments.
  maxTableCols   = 13,
  barTables      = 3,
  legendPairs    = 4,
  maxGraphShips  = 8,
  maxTotalPoints = 300,
  maxYRoundTo    = 1000,
  topLimits      = { 10, 25, 50, 100 },
  point = { type = "square", size = 5 },
  line  = { type = "normal", size = 2 },
  seriesColors = {
    Color["graph_data_1"], Color["graph_data_2"], Color["graph_data_3"], Color["graph_data_4"],
    Color["graph_data_5"], Color["graph_data_6"], Color["graph_data_7"], Color["graph_data_8"],
  },
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

local function isRanked(view)
  return view == "shipsbywares" or view == "waresbyships" or view == "cargoload"
end

-- *** registration ***

local function init()
  Menus = Menus or {}
  table.insert(Menus, menu)
  if Helper then
    Helper.registerMenu(menu)
  end
end

function menu.cleanup()
  menu.infoFrame = nil
  menu.graph = nil
end

-- Opened from the map's interaction menu, so "back" is pointed at the map
-- explicitly; without a back-target Helper.closeMenu falls through to the
-- engine's generic top-level fallback instead.
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
  menu.topLimit   = 25
  menu.reverse    = false
  menu.selectedShip = nil
  menu.graphShips = {}
  menu.expanded   = {}
  menu.partColors = {}
  menu.nextPartColor = 1
end

local function shipByIdcode(idcode)
  for _, ship in ipairs(sta.ships) do
    if ship.idcode == idcode then
      return ship
    end
  end
  return nil
end

-- Stable per-key colour: assigned on first sight and kept for the session, so a
-- ware keeps its colour when the ranking reshuffles under a filter change.
local function colorFor(key)
  local c = menu.partColors[key]
  if c == nil then
    c = config.seriesColors[((menu.nextPartColor - 1) % #config.seriesColors) + 1]
    menu.partColors[key] = c
    menu.nextPartColor = menu.nextPartColor + 1
  end
  return c
end

-- *** mode-agnostic data access ***

local function shipRows()
  if menu.mode == "trades" then
    return staTrades.filteredShips(menu.filter, menu.sortBy)
  end
  return sta.filteredShips(menu.filter, menu.sortBy)
end

local function rankedRows(groupBy)
  if menu.mode == "trades" then
    return staTrades.rankedBreakdown(menu.filter, groupBy, menu.topLimit, menu.reverse)
  end
  return sta.rankedBreakdown(menu.filter, groupBy, menu.topLimit, menu.reverse)
end

local function cargoLoadRows()
  if menu.mode == "trades" then
    return staTrades.cargoLoad(menu.filter, menu.topLimit, menu.reverse)
  end
  return sta.cargoLoad(menu.filter, menu.topLimit, menu.reverse)
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

-- Min/max-per-bucket decimation: keeps the extreme of every bucket, so a spike
-- is never smoothed away the way fixed-interval resampling would smooth it.
-- First and last points are always kept verbatim.
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

-- Ships currently plotted, defaulting to the selected one so the graph is never
-- blank just because nothing was explicitly ticked.
local function graphShipList()
  local list = {}
  for _, entry in ipairs(shipRows()) do
    if menu.graphShips[entry.ship.idcode] then
      list[#list + 1] = entry.ship
    end
  end
  if #list == 0 and menu.selectedShip ~= nil then
    local ship = shipByIdcode(menu.selectedShip)
    if ship ~= nil then
      list[1] = ship
    end
  end
  return list
end

-- Timestamped events feeding the profit graph, per analysis mode: a completed
-- trade books its whole profit at the moment it closed.
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
  -- Anchor at zero just before the first event so a line always starts on the
  -- baseline instead of jumping in mid-air.
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

  sta.ensureScanned()

  -- Opened on a specific object: a ship preselects itself, a station preselects
  -- itself as the parent-station filter.
  local id64 = menu.param[3]
  if id64 ~= nil and id64 ~= 0 then
    local luaId = ConvertStringToLuaID(tostring(id64))
    local idcode = GetComponentData(luaId, "idcode")
    if idcode ~= nil then
      if IsComponentClass(luaId, "station") then
        menu.filter.parentStation = idcode
      elseif shipByIdcode(idcode) ~= nil then
        menu.selectedShip = idcode
      end
    end
  end

  menu.createFrame()
end

function menu.viewCreated(_layer, ...)
  -- Called unconditionally by the engine on every display(); the tables are
  -- rebuilt from scratch each refresh, so nothing needs keeping.
end

function menu.refreshInfoFrame()
  menu.createFrame()
end

function menu.buttonRefresh()
  sta.scan()
  -- Cached pairings belong to the previous scan.
  menu.expanded = {}
  menu.refreshInfoFrame()
end

function menu.selectMode(_, id)
  if id ~= menu.mode then
    menu.mode = id
    menu.expanded = {}
    menu.refreshInfoFrame()
  end
end

function menu.selectView(_, id)
  if id ~= menu.view then
    menu.view = id
    menu.refreshInfoFrame()
  end
end

function menu.selectParentStation(_, id)
  menu.filter.parentStation = id
  menu.refreshInfoFrame()
end

function menu.selectShipClass(_, id)
  menu.filter.shipClass = id
  menu.refreshInfoFrame()
end

function menu.selectCargoType(_, id)
  menu.filter.cargoType = id
  menu.refreshInfoFrame()
end

function menu.selectSort(_, id)
  menu.sortBy = id
  menu.refreshInfoFrame()
end

function menu.selectTop(_, id)
  menu.topLimit = math.floor(tonumber(id) or 25)
  menu.refreshInfoFrame()
end

function menu.toggleInternal(checked)
  menu.filter.internalTrades = checked
  menu.refreshInfoFrame()
end

function menu.toggleReverse(checked)
  menu.reverse = checked
  menu.refreshInfoFrame()
end

-- In the graph view a ship row toggles plotting; everywhere else it selects.
function menu.clickShip(idcode)
  if menu.view == "graph" then
    if menu.graphShips[idcode] then
      menu.graphShips[idcode] = nil
    else
      local count = 0
      for _ in pairs(menu.graphShips) do count = count + 1 end
      if count < config.maxGraphShips then
        menu.graphShips[idcode] = true
      end
    end
  end
  menu.selectedShip = idcode
  menu.refreshInfoFrame()
end

function menu.toggleExpanded(key)
  menu.expanded[key] = (not menu.expanded[key]) or nil
  menu.refreshInfoFrame()
end

-- *** frame ***

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
  local leftWidth   = Helper.round(usableWidth * config.leftPanelShare)
  local rightX      = Helper.frameBorder + leftWidth + Helper.borderSize
  local rightWidth  = usableWidth - leftWidth - Helper.borderSize

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

-- A checkbox without an explicit width stretches over the whole cell, and cells
-- have no halign for non-text widgets, so the box is squared and centred by hand.
local function createCenteredCheckBox(cell, checked)
  local size = Helper.scaleX(Helper.standardTextHeight)
  cell:createCheckBox(checked, { width = size, height = size, scaling = false })
  cell.properties.x = math.max(0, math.floor((cell:getColSpanWidth() - size) / 2))
  return cell
end

function menu.createLeftPanel(x, width)
  local leftTable = menu.infoFrame:addTable(2, {
    tabOrder = 1, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  local row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(2):createText(ReadText(PAGE, 1000), Helper.titleTextProperties)

  -- Analysis mode
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1001), { halign = "left" })
  local modeEntries = {}
  for _, m in ipairs(modes) do
    modeEntries[#modeEntries + 1] = { id = m.id, text = ReadText(PAGE, m.text) }
  end
  row[2]:createDropDown(dropdownOptions(modeEntries), { startOption = menu.mode, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectMode

  -- View
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1002), { halign = "left" })
  local viewEntries = {}
  for _, v in ipairs(views) do
    viewEntries[#viewEntries + 1] = { id = v.id, text = ReadText(PAGE, v.text) }
  end
  row[2]:createDropDown(dropdownOptions(viewEntries), { startOption = menu.view, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectView

  -- Filters
  row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(2):createText(ReadText(PAGE, 121), Helper.titleTextProperties)

  local stationEntries = {
    { id = "any",  text = ReadText(PAGE, 107) },
    { id = "none", text = ReadText(PAGE, 108) },
  }
  for _, station in ipairs(sta.stations) do
    stationEntries[#stationEntries + 1] = { id = station.idcode, text = station.name }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1003), { halign = "left" })
  row[2]:createDropDown(dropdownOptions(stationEntries), { startOption = menu.filter.parentStation, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectParentStation

  local classEntries = { { id = "all", text = ReadText(PAGE, 109) } }
  for _, classId in ipairs(sta.shipClasses) do
    classEntries[#classEntries + 1] = { id = classId, text = sta.classLetter(classId) }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1004), { halign = "left" })
  row[2]:createDropDown(dropdownOptions(classEntries), { startOption = menu.filter.shipClass, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectShipClass

  local cargoEntries = {}
  for _, c in ipairs(cargoTypes) do
    cargoEntries[#cargoEntries + 1] = { id = c.id, text = ReadText(PAGE, c.text) }
  end
  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1005), { halign = "left" })
  row[2]:createDropDown(dropdownOptions(cargoEntries), { startOption = menu.filter.cargoType, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectCargoType

  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1006), { halign = "left" })
  createCenteredCheckBox(row[2], menu.filter.internalTrades)
  row[2].handlers.onClick = function(_, checked) return menu.toggleInternal(checked) end

  row = leftTable:addRow(true, { fixed = true })
  row[1]:createText(ReadText(PAGE, 1007), { halign = "left" })
  local sortEntries = {
    { id = "profit", text = ReadText(PAGE, 1009) },
    { id = "name",   text = ReadText(PAGE, 1008) },
  }
  row[2]:createDropDown(dropdownOptions(sortEntries), { startOption = menu.sortBy, height = Helper.standardButtonHeight })
  row[2].handlers.onDropDownConfirmed = menu.selectSort

  if isRanked(menu.view) then
    row = leftTable:addRow(true, { fixed = true })
    row[1]:createText(ReadText(PAGE, 1010), { halign = "left" })
    local topEntries = {}
    for _, limit in ipairs(config.topLimits) do
      topEntries[#topEntries + 1] = { id = tostring(limit), text = tostring(limit) }
    end
    row[2]:createDropDown(dropdownOptions(topEntries), { startOption = tostring(menu.topLimit), height = Helper.standardButtonHeight })
    row[2].handlers.onDropDownConfirmed = menu.selectTop

    row = leftTable:addRow(true, { fixed = true })
    row[1]:createText(ReadText(PAGE, 1011), { halign = "left" })
    createCenteredCheckBox(row[2], menu.reverse)
    row[2].handlers.onClick = function(_, checked) return menu.toggleReverse(checked) end
  end

  row = leftTable:addRow(true, { fixed = true })
  row[1]:setColSpan(2):createButton({}):setText(ReadText(PAGE, 1012), { halign = "center" })
  row[1].handlers.onClick = function() return menu.buttonRefresh() end

  -- Ship list
  local rows = shipRows()
  local totalProfit = 0
  for _, entry in ipairs(rows) do
    totalProfit = totalProfit + entry.profit
  end

  row = leftTable:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:createText(ReadText(PAGE, 122), Helper.titleTextProperties)
  row[2]:createText(sta.formatMoney(totalProfit), {
    halign = "right", color = (totalProfit >= 0) and Color["text_positive"] or Color["text_negative"],
  })

  if #rows == 0 then
    row = leftTable:addRow(false, {})
    row[1]:setColSpan(2):createText(sta.scanned and ReadText(PAGE, 1016) or ReadText(PAGE, 1015),
      { halign = "center", wordwrap = true, color = Color["text_inactive"] })
    return
  end

  for _, entry in ipairs(rows) do
    local idcode = entry.ship.idcode
    local selected = (idcode == menu.selectedShip)
    local prefix = ""
    if menu.view == "graph" then
      prefix = menu.graphShips[idcode] and "\027[widget_ok]  " or ""
    end
    row = leftTable:addRow("ship_" .. idcode, {})
    local nameColor
    if menu.view == "graph" and menu.graphShips[idcode] then
      nameColor = colorFor(idcode)
    elseif selected then
      nameColor = Color["text_positive"]
    end
    row[1]:createText(prefix .. entry.ship.classLetter .. " " .. entry.ship.fullName,
      { halign = "left", color = nameColor })
    row[2]:createText(sta.formatMoney(entry.profit), {
      halign = "right", color = (entry.profit >= 0) and Color["text_positive"] or Color["text_negative"],
    })
    row[1].handlers.onClick = function() return menu.clickShip(idcode) end
    row[2].handlers.onClick = function() return menu.clickShip(idcode) end
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
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  local row = t:addRow(false, { fixed = true })
  row[1]:createText(ReadText(PAGE, textId), { halign = "center", wordwrap = true, color = Color["text_inactive"] })
end

function menu.createTransactionsPanel(x, width)
  local ship = menu.selectedShip and shipByIdcode(menu.selectedShip) or nil
  if ship == nil then
    return emptyPanel(x, width, 1017)
  end

  local transactions = sta.filteredTransactions(ship, menu.filter)
  if #transactions == 0 then
    return emptyPanel(x, width, 1016)
  end

  local t = menu.infoFrame:addTable(10, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(10):createText(ship.fullName, Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[1]:createText(ReadText(PAGE, 110), { halign = "left" })
  row[2]:createText(ReadText(PAGE, 111), { halign = "left" })
  row[3]:createText(ReadText(PAGE, 112), { halign = "left" })
  row[4]:createText(ReadText(PAGE, 117), { halign = "left" })
  row[5]:createText(ReadText(PAGE, 118), { halign = "left" })
  row[6]:createText(ReadText(PAGE, 113), { halign = "right" })
  row[7]:createText(ReadText(PAGE, 114), { halign = "right" })
  row[8]:createText(ReadText(PAGE, 115), { halign = "right" })
  row[9]:createText(ReadText(PAGE, 116), { halign = "right" })
  row[10]:createText(ReadText(PAGE, 119), { halign = "right" })

  -- Newest first: the recent tail is what anyone opening this actually wants.
  for i = #transactions, 1, -1 do
    local tx = transactions[i]
    row = t:addRow(false, {})
    row[1]:createText(sta.formatAgo(tx.t), { halign = "left" })
    row[2]:createText(ReadText(PAGE, tx.sale and 1019 or 1018),
      { halign = "left", color = tx.sale and Color["text_positive"] or Color["text_negative"] })
    row[3]:createText(sta.getWare(tx.ware).name, { halign = "left" })
    row[4]:createText(tx.pName, { halign = "left" })
    row[5]:createText(tx.pSector, { halign = "left" })
    row[6]:createText(sta.formatMoney(tx.price), { halign = "right" })
    row[7]:createText(tostring(tx.vol), { halign = "right" })
    row[8]:createText(sta.formatMoney(tx.sale and tx.sum or -tx.sum),
      { halign = "right", color = tx.sale and Color["text_positive"] or Color["text_negative"] })
    row[9]:createText(sta.formatMoney(tx.profit),
      { halign = "right", color = (tx.profit >= 0) and Color["text_positive"] or Color["text_negative"] })
    row[10]:createText(string.format("%.0f%%", tx.load), { halign = "right" })
  end
end

function menu.createTradesPanel(x, width)
  local ship = menu.selectedShip and shipByIdcode(menu.selectedShip) or nil
  if ship == nil then
    return emptyPanel(x, width, 1017)
  end

  local trades = staTrades.filteredTrades(ship, menu.filter)
  if #trades == 0 then
    return emptyPanel(x, width, 1016)
  end

  local t = menu.infoFrame:addTable(8, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(8):createText(ship.fullName, Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[1]:createText(ReadText(PAGE, 110), { halign = "left" })
  row[2]:createText(ReadText(PAGE, 112), { halign = "left" })
  row[3]:createText(ReadText(PAGE, 130), { halign = "right" })
  row[4]:createText(ReadText(PAGE, 131), { halign = "right" })
  row[5]:createText(ReadText(PAGE, 132), { halign = "right" })
  row[6]:createText(ReadText(PAGE, 133), { halign = "right" })
  row[7]:createText(ReadText(PAGE, 119), { halign = "right" })
  row[8]:createText("", { halign = "right" })

  for i = #trades, 1, -1 do
    local trade = trades[i]
    local key = ship.idcode .. "#" .. i
    row = t:addRow("trade_" .. key, {})
    row[1]:createText(sta.formatAgo(trade.startTime), { halign = "left" })
    row[2]:createText(sta.getWare(trade.ware).name, { halign = "left" })
    row[3]:createText(sta.formatMoney(trade.buyCost), { halign = "right" })
    row[4]:createText(sta.formatMoney(trade.revenue), { halign = "right" })
    row[5]:createText(sta.formatMoney(trade.profit),
      { halign = "right", color = (trade.profit >= 0) and Color["text_positive"] or Color["text_negative"] })
    row[6]:createText(sta.formatDuration(trade.duration), { halign = "right" })
    row[7]:createText(string.format("%.0f%%", trade.load), { halign = "right" })
    row[8]:createButton({}):setText(menu.expanded[key] and "-" or "+", { halign = "center" })
    row[8].handlers.onClick = function() return menu.toggleExpanded(key) end

    if menu.expanded[key] then
      local function legRow(leg, isSale)
        local legrow = t:addRow(false, { bgColor = Color["row_background_unselectable"] })
        legrow[1]:createText(sta.formatAgo(leg.t), { halign = "left" })
        legrow[2]:createText(ReadText(PAGE, isSale and 1019 or 1018),
          { halign = "left", color = isSale and Color["text_positive"] or Color["text_negative"] })
        legrow[3]:setColSpan(2):createText(leg.station, { halign = "left" })
        legrow[5]:createText(leg.sector, { halign = "left" })
        legrow[6]:createText(sta.formatMoney(leg.price), { halign = "right" })
        legrow[7]:createText(tostring(leg.vol), { halign = "right" })
      end
      for _, leg in ipairs(trade.purchases) do legRow(leg, false) end
      for _, leg in ipairs(trade.sales) do legRow(leg, true) end
    end
  end
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
      lines[#lines + 1] = { id = ship.idcode, ship = ship, points = points, need = #points }
    end
  end
  if #lines == 0 then
    return emptyPanel(x, width, 1016)
  end

  local totalPoints = 0
  for _, line in ipairs(lines) do
    totalPoints = totalPoints + line.need
  end
  local caps = (totalPoints > config.maxTotalPoints) and fairShareCaps(lines, config.maxTotalPoints) or nil

  local graphHeight = math.floor(width * 9 / 16)
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
    local color = colorFor(line.id)
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

  -- Legend: the graph widget has none, and the ship list only colours rows that
  -- are currently plotted.
  local legend = menu.infoFrame:addTable(2, {
    tabOrder = 3, width = width, x = x,
    y = t.properties.y + t:getFullHeight() + Helper.borderSize,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  legend:setColWidth(1, Helper.standardTextHeight)
  for _, line in ipairs(lines) do
    local legendRow = legend:addRow(false, {})
    legendRow[1]:createText("")
    legendRow[1].properties.cellBGColor = colorFor(line.id)
    legendRow[2]:createText(line.ship.fullName, { halign = "left" })
  end
end

-- Horizontal stacked bar built from background-coloured cells: the only way to
-- get a segmented bar out of the X4 table widget, which has no bar chart. A table
-- is capped at 13 columns, so the bar is spread over config.barTables tables put
-- side by side; every row exists in all of them, which keeps the rows aligned.
function menu.createRankedPanel(x, width, groupBy)
  local groups = rankedRows(groupBy)
  if #groups == 0 then
    return emptyPanel(x, width, 1016)
  end

  local maxTotal = 0 ---@type number
  for _, g in ipairs(groups) do
    maxTotal = math.max(maxTotal, math.abs(g.total))
  end
  if maxTotal <= 0 then
    maxTotal = 1
  end

  local numTables = math.max(1, config.barTables)
  local cols      = config.maxTableCols
  local segments  = numTables * cols - 2
  local labelWidth = math.floor(width * 0.3)
  local totalWidth = math.floor(width * 0.18)
  -- Every table has cols-1 inner borders, plus one gap between adjacent tables.
  local borders   = (numTables * (cols - 1) + numTables - 1) * Helper.borderSize
  local segWidth  = math.max(1, math.floor((width - labelWidth - totalWidth - borders) / segments))
  -- Whatever flooring the segments left over goes to the total column, so the
  -- panel still ends flush with the right edge.
  local restWidth = math.floor(width - labelWidth - borders - segments * segWidth)
  if restWidth > totalWidth then
    totalWidth = restWidth
  end

  -- The name occupies the very first cell and the total the very last one; all
  -- the rest are equally wide bar segments, which is what makes the split seamless.
  local function colWidth(k, col)
    if (k == 1) and (col == 1) then
      return labelWidth
    elseif (k == numTables) and (col == cols) then
      return totalWidth
    end
    return segWidth
  end

  local tables, tableX = {}, x
  for k = 1, numTables do
    local tableWidth = (cols - 1) * Helper.borderSize
    for col = 1, cols do
      tableWidth = tableWidth + colWidth(k, col)
    end
    local t = menu.infoFrame:addTable(cols, {
      tabOrder = 1 + k, width = tableWidth, x = tableX, y = Helper.frameBorder, borderEnabled = true,
      backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
    })
    for col = 1, cols do
      t:setColWidth(col, colWidth(k, col), false)
    end
    tables[k] = t
    tableX = tableX + tableWidth + Helper.borderSize
  end

  -- Title styling on all of them, or the continuation tables would start a row higher.
  for k, t in ipairs(tables) do
    local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
    row[1]:setColSpan(cols):createText((k == 1) and ReadText(PAGE, (groupBy == "ware") and 105 or 104) or "",
      Helper.titleTextProperties)
  end

  for _, g in ipairs(groups) do
    local rows = {}
    for k, t in ipairs(tables) do
      rows[k] = t:addRow(false, {})
    end
    rows[1][1]:createText(g.name, { halign = "left" })

    -- Segment i is the (i+1)-th cell counted across all tables.
    local function segmentCell(i)
      return rows[math.floor(i / cols) + 1][i % cols + 1]
    end

    -- Bar length is the group's share of the largest total, so rows stay
    -- comparable; segment widths inside it are each part's share of the group.
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
        -- A segment is a bare coloured cell, so the legend text is its only label.
        cell:createText("", { mouseOverText = p.name })
        cell.properties.cellBGColor = colorFor(p.key)
      end
    end

    rows[numTables][cols]:createText(sta.formatMoney(g.total), {
      halign = "right", color = (g.total >= 0) and Color["text_positive"] or Color["text_negative"],
    })
  end

  -- Legend for whatever the segments turned out to be.
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

  -- Each pair is a narrow swatch cell plus a wide name cell.
  local legendPairs = config.legendPairs
  local legend = menu.infoFrame:addTable(legendPairs * 2, {
    tabOrder = 2 + numTables, width = width, x = x,
    y = tables[1].properties.y + tables[1]:getFullHeight() + Helper.borderSize,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  for i = 1, legendPairs do
    legend:setColWidth(i * 2 - 1, Helper.standardTextHeight)
  end
  for i = 1, #legendEntries, legendPairs do
    local legendRow = legend:addRow(false, {})
    for j = 0, legendPairs - 1 do
      local entry = legendEntries[i + j]
      if entry ~= nil then
        legendRow[j * 2 + 1]:createText("")
        legendRow[j * 2 + 1].properties.cellBGColor = colorFor(entry.key)
        legendRow[j * 2 + 2]:createText(entry.name, { halign = "left" })
      end
    end
  end
end

function menu.createCargoLoadPanel(x, width)
  local rows = cargoLoadRows()
  if #rows == 0 then
    return emptyPanel(x, width, 1016)
  end

  local t = menu.infoFrame:addTable(4, {
    tabOrder = 2, width = width, x = x, y = Helper.frameBorder, borderEnabled = true,
    backgroundID = "solid", backgroundColor = Color["frame_background_semitransparent"],
  })
  t:setColWidth(1, Helper.round(width * 0.34), false)
  t:setColWidth(3, Helper.round(width * 0.12), false)
  t:setColWidth(4, Helper.round(width * 0.12), false)

  local row = t:addRow(false, { fixed = true, bgColor = Color["row_title_background"] })
  row[1]:setColSpan(4):createText(ReadText(PAGE, 106), Helper.titleTextProperties)

  row = t:addRow(false, { fixed = true, bgColor = Color["row_background_unselectable"] })
  row[1]:createText(ReadText(PAGE, 122), { halign = "left" })
  row[2]:createText(ReadText(PAGE, 119), { halign = "left" })
  row[3]:createText(ReadText(PAGE, 1025), { halign = "right" })
  row[4]:createText(ReadText(PAGE, 1026), { halign = "right" })

  for _, entry in ipairs(rows) do
    row = t:addRow(false, {})
    row[1]:createText(entry.name, { halign = "left" })
    row[2]:createStatusBar({
      current = entry.average, start = 0, max = 100,
      valueColor = colorFor(entry.key), height = Helper.standardTextHeight, scaling = false,
    })
    row[3]:createText(string.format("%.0f%%", entry.average), { halign = "right" })
    row[4]:createText(string.format("%.0f%%", entry.best), { halign = "right" })
  end
end

-- *** standard menu callbacks ***

function menu.onUpdate()
  if menu.infoFrame then
    menu.infoFrame:update()
  end
end

function menu.onCloseElement(dueToClose)
  Helper.closeMenu(menu, dueToClose)
  menu.cleanup()
end

-- State is left unset here on purpose: menu.onShowMenu builds it on first open,
-- by which point MD has populated the config blackboard this mod reads its
-- filter defaults from.
local function Init()
  init()
  RegisterEvent("ShipsTradeAnalyzer.OpenMenu", onOpenMenuEvent)
end

Register_OnLoad_Init(Init)
