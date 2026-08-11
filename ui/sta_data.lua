-- Ships Trade Analyzer - data layer.
--
-- Reads the engine's own trade log per player-owned ship (C.GetTransactionLog)
-- and turns it into per-ship transaction lists plus the aggregates the menu
-- views need. Nothing is sampled or persisted -- the log already lives in the
-- save; this module only ever reads it.
--
-- TransactionLogEntry, StorageInfo, GetNumTransactionLog, GetTransactionLog,
-- GetNumCargoTransportTypes and GetCargoTransportTypes are all declared by
-- vanilla (ego_detailmonitorhelper/helper.lua, ego_detailmonitor/menu_map.lua)
-- with identical layouts in 8.00 and 9.00, so they are used from the shared
-- ffi namespace rather than re-declared here.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;
  double     GetCurrentGameTime(void);
  UniverseID GetPlayerID(void);
  bool       IsComponentOperational(UniverseID componentid);
]]

local sta = {
  playerId   = nil,
  debugLevel = "none",
  -- Set false at init if the engine no longer exposes the trade-log API under
  -- the names vanilla declares; every scan then no-ops instead of erroring.
  available  = false,

  ships      = {},   -- array of ship records, see buildShip()
  stations   = {},   -- array of { idcode, name } - parent-station filter options
  wareCache  = {},   -- [wareId] = { name, transport, volume, avgprice }

  scanTime      = 0, -- game time the last scan ran at
  scanned       = false,
  totalEntries  = 0, -- trade entries kept across every ship
  skippedShips  = 0, -- ships whose log exceeded maxEntriesPerShip
}

local config = {
  -- Per-ship hard cap on kept trade entries. A ship past this is still listed
  -- with its aggregates, but its oldest entries are dropped so a decades-long
  -- save cannot blow the UI Lua heap.
  maxEntriesPerShip = 5000,
  -- Wares the engine reports without a usable per-unit volume against ship
  -- capacity; their load percentage is meaningless, so it reads as full.
  fullLoadWares = { rawscrap = true },
}

-- *** debug helpers ***
-- Lazy formatting: args are only expanded once the level allows output.

local function debugLog(fmt, ...)
  if sta.debugLevel ~= "none" then
    if select("#", ...) > 0 then
      DebugError("[STA] " .. string.format(fmt, ...))
    else
      DebugError("[STA] " .. fmt)
    end
  end
end

local function traceLog(fmt, ...)
  if sta.debugLevel == "trace" then
    if select("#", ...) > 0 then
      DebugError("[STA] " .. string.format(fmt, ...))
    else
      DebugError("[STA] " .. fmt)
    end
  end
end

sta.debugLog = debugLog
sta.traceLog = traceLog

function sta.onDebugLevelChanged()
  local cfg = GetNPCBlackboard(sta.playerId, "$ShipsTradeAnalyzerConfig")
  if cfg ~= nil and cfg.debugLevel ~= nil then
    sta.debugLevel = tostring(cfg.debugLevel)
    debugLog("Debug level changed to %s.", sta.debugLevel)
  end
end

function sta.getConfig()
  return GetNPCBlackboard(sta.playerId, "$ShipsTradeAnalyzerConfig") or {}
end

-- *** formatting (local: both vanilla equivalents are 9.00-only) ***

function sta.formatDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  if h > 0 then
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dm %02ds", m, seconds % 60)
end

function sta.formatAgo(t, now)
  return sta.formatDuration((now or sta.scanTime) - t)
end

function sta.formatMoney(value)
  return ConvertMoneyString(math.floor(value + 0.5), false, true, 0, true) .. " " .. ReadText(1001, 101)
end

-- Faction-coloured object icon; Helper.createIconStringFactionColored is 9.00-only.
function sta.iconString(luaId)
  if luaId == nil then
    return ""
  end
  local icon, faction = GetComponentData(luaId, "icon", "owner")
  if icon == nil or icon == "" then
    return ""
  end
  local factioncolor = faction and GetFactionData(faction, "color") or nil
  if factioncolor then
    return string.format("%s\027[%s]\27X ", Helper.convertColorToText(factioncolor), icon)
  end
  return string.format("\027[%s] ", icon)
end

-- *** ware metadata ***

function sta.getWare(wareId)
  local w = sta.wareCache[wareId]
  if w == nil then
    local name, transport, volume, avgprice = GetWareData(wareId, "name", "transport", "volume", "avgprice")
    w = {
      name      = name or wareId,
      transport = transport or "container",
      volume    = tonumber(volume) or 1,
      avgprice  = tonumber(avgprice) or 0,
    }
    sta.wareCache[wareId] = w
  end
  return w
end

-- *** ship metadata ***

-- Ordered largest-first; IsComponentClass is the only reliable way to get a
-- ship's size class ("class" is not a GetComponentData key).
sta.shipClasses = { "ship_xl", "ship_l", "ship_m", "ship_s" }

local classLetters = {
  ship_xl = "XL",
  ship_l  = "L",
  ship_m  = "M",
  ship_s  = "S",
}

function sta.classLetter(classId)
  return classLetters[classId or ""] or "?"
end

local function shipClassOf(luaId)
  for _, classId in ipairs(sta.shipClasses) do
    if IsComponentClass(luaId, classId) then
      return classId
    end
  end
  return ""
end

local function cargoCapacities(id64)
  local caps = {}
  local n = tonumber(C.GetNumCargoTransportTypes(id64, true)) or 0
  if n > 0 then
    local buf = ffi.new("StorageInfo[?]", n)
    n = tonumber(C.GetCargoTransportTypes(buf, n, id64, true, false)) or 0
    for i = 0, n - 1 do
      caps[ffi.string(buf[i].transport)] = tonumber(buf[i].capacity) or 0
    end
  end
  return caps
end

-- Station the ship reports to, walked up the commander chain: a subordinate of
-- a fleet led by a station-based commander still belongs to that station.
-- The depth cap guards against a malformed cycle, not against deep fleets.
local function parentStation(luaId)
  local current = GetCommander(luaId)
  for _ = 1, 8 do
    if current == nil or current == 0 then
      break
    end
    if IsComponentClass(current, "station") then
      local idcode, name = GetComponentData(current, "idcode", "name")
      return idcode, name
    end
    current = GetCommander(current)
  end
  return nil, nil
end

-- *** counterpart resolution ***
--
-- The trade entry names both sides; the counterpart is simply whichever of
-- buyerid/sellerid is not this ship. Falls back to the entry's own partner
-- name/idcode strings when the component is gone, so a trade with a destroyed
-- station still reads sensibly.
local function counterpartInfo(otherId, entryPartnerName, entryPartnerIdcode)
  local info = { name = "", idcode = "", owner = "", sector = "", luaId = nil }
  if otherId ~= nil and otherId ~= 0 and C.IsComponentOperational(otherId) then
    local luaId = ConvertStringToLuaID(tostring(otherId))
    local name, idcode, owner, sector = GetComponentData(luaId, "name", "idcode", "owner", "sector")
    info.luaId  = luaId
    info.name   = name or ""
    info.idcode = idcode or ""
    info.owner  = owner or ""
    info.sector = sector or ""
  end
  if info.name == "" then
    info.name   = entryPartnerName or ""
    info.idcode = entryPartnerIdcode or ""
  end
  return info
end

local function displayName(name, idcode)
  if name == "" or name == nil then
    return idcode or ""
  end
  if idcode == nil or idcode == "" then
    return name
  end
  return name .. " (" .. idcode .. ")"
end

-- *** scanning ***

-- Estimated profit, mirroring X4PlayerShipTradeAnalyzer: for container wares
-- the reference is the ware's average price, so a purchase below average
-- already books profit; anything not shipped in containers (mined ore, gas,
-- liquids) has no meaningful purchase reference, so the sale sum is the profit.
local function estimateProfit(ware, isSale, sum, volume)
  if ware.transport == "container" then
    local reference = ware.avgprice * volume
    if isSale then
      return sum - reference
    end
    return reference - sum
  end
  return isSale and sum or -sum
end

local function readShipLog(ship, startTime, endTime)
  local id64 = ship.id64
  local total = tonumber(C.GetNumTransactionLog(id64, startTime, endTime)) or 0
  if total <= 0 then
    return
  end

  local buf = ffi.new("TransactionLogEntry[?]", total)
  total = tonumber(C.GetTransactionLog(buf, total, id64, startTime, endTime)) or 0

  -- Oldest entries are dropped first, so a capped ship still shows its most
  -- recent trading rather than an arbitrary early slice.
  local firstIndex = 0 ---@type number
  if total > config.maxEntriesPerShip then
    firstIndex = total - config.maxEntriesPerShip
    sta.skippedShips = sta.skippedShips + 1
    debugLog("readShipLog: %s has %d entries, keeping the newest %d.",
      ship.fullName, total, config.maxEntriesPerShip)
  end

  for i = firstIndex, total - 1 do
    if ffi.string(buf[i].eventtype) == "trade" then
      local wareId = ffi.string(buf[i].ware)
      if wareId ~= "" then
        local amount = tonumber(buf[i].amount) or 0
        local price  = (tonumber(buf[i].price) or 0) / 100
        if amount > 0 and price > 0 then
          local money    = (tonumber(buf[i].money) or 0) / 100
          local sellerId = buf[i].sellerid
          -- Same test vanilla uses in Helper.createTransactionLog: trust the
          -- explicit seller id, fall back to the sign of the money change.
          local isSale = (sellerId ~= 0 and sellerId == id64) or (sellerId == 0 and money >= 0)
          local otherId = isSale and buf[i].buyerid or sellerId
          local partner = counterpartInfo(otherId,
            ffi.string(buf[i].partnername), ffi.string(buf[i].partneridcode))

          local ware = sta.getWare(wareId)
          local sum  = price * amount
          local used = amount * ware.volume
          local capacity = ship.capacity[ware.transport]
          local load ---@type number
          if config.fullLoadWares[wareId] or capacity == nil or capacity <= 0 then
            load = 100
          else
            load = math.min(100, used / capacity * 100)
          end

          local tx = {
            t        = tonumber(buf[i].time) or 0,
            sale     = isSale,
            ware     = wareId,
            price    = price,
            vol      = amount,
            sum      = sum,
            profit   = estimateProfit(ware, isSale, sum, amount),
            used     = used,
            load     = load,
            pName    = displayName(partner.name, partner.idcode),
            pOwner   = partner.owner,
            pSector  = partner.sector,
            pLuaId   = partner.luaId,
          }
          ship.tx[#ship.tx + 1] = tx
          ship.profit  = ship.profit + tx.profit
          ship.turnover = ship.turnover + sum
          sta.totalEntries = sta.totalEntries + 1
        end
      end
    end
  end

  -- The engine returns entries newest-first in places; the pairing pass and the
  -- profit graph both assume ascending time.
  table.sort(ship.tx, function(a, b) return a.t < b.t end)
  traceLog("readShipLog: %s kept %d trade entries.", ship.fullName, #ship.tx)
end

local function buildShip(luaId)
  local name, idcode, sector = GetComponentData(luaId, "name", "idcode", "sector")
  local classId = shipClassOf(luaId)
  local stationIdcode, stationName = parentStation(luaId)
  local id64 = ConvertIDTo64Bit(luaId)
  return {
    luaId       = luaId,
    id64        = id64,
    name        = name or "",
    idcode      = idcode or "",
    fullName    = displayName(name, idcode),
    classId     = classId or "",
    classLetter = sta.classLetter(classId),
    sector      = sector or "",
    stationIdcode = stationIdcode,
    stationName   = stationIdcode and displayName(stationName, stationIdcode) or nil,
    capacity    = cargoCapacities(id64),
    tx          = {},
    profit      = 0,
    turnover    = 0,
  }
end

function sta.scan()
  if not sta.available then
    debugLog("scan: trade-log API unavailable, nothing to do.")
    return
  end

  local now = C.GetCurrentGameTime()

  sta.ships = {}
  sta.stations = {}
  sta.totalEntries = 0
  sta.skippedShips = 0
  sta.scanTime = now

  local stationSeen = {}
  local objects = GetContainedObjectsByOwner("player")
  for _, luaId in ipairs(objects) do
    if IsComponentClass(luaId, "ship") and not IsComponentClass(luaId, "spacesuit") then
      local ship = buildShip(luaId)
      readShipLog(ship, 0, now)
      if #ship.tx > 0 then
        sta.ships[#sta.ships + 1] = ship
        if ship.stationIdcode ~= nil and not stationSeen[ship.stationIdcode] then
          stationSeen[ship.stationIdcode] = true
          sta.stations[#sta.stations + 1] = { idcode = ship.stationIdcode, name = ship.stationName }
        end
      end
    end
  end

  table.sort(sta.stations, function(a, b) return a.name < b.name end)
  sta.scanned = true
  debugLog("scan: %d trading ship(s), %d trade entries.", #sta.ships, sta.totalEntries)
end

function sta.ensureScanned()
  if not sta.scanned then
    sta.scan()
  end
end

-- *** filtering ***

function sta.defaultFilter()
  local cfg = sta.getConfig()
  return {
    parentStation  = "any",   -- "any" | "none" | <station idcode>
    shipClass      = "all",   -- "all" | ship_xl | ship_l | ship_m | ship_s
    cargoType      = "all",   -- "all" | container | solid | liquid | gas
    internalTrades = not (cfg.includeInternalTrades == false or cfg.includeInternalTrades == 0),
  }
end

function sta.shipMatches(ship, filter)
  if filter.shipClass ~= "all" and ship.classId ~= filter.shipClass then
    return false
  end
  if filter.parentStation == "none" then
    return ship.stationIdcode == nil
  elseif filter.parentStation ~= "any" then
    return ship.stationIdcode == filter.parentStation
  end
  return true
end

function sta.txMatches(tx, filter)
  if filter.cargoType ~= "all" and sta.getWare(tx.ware).transport ~= filter.cargoType then
    return false
  end
  if not filter.internalTrades and tx.pOwner == "player" then
    return false
  end
  return true
end

-- Ships passing the filter, each with the profit/turnover/count of only the
-- transactions that also pass it. Sorted by "name" or "profit".
function sta.filteredShips(filter, sortBy)
  local result = {}
  for _, ship in ipairs(sta.ships) do
    if sta.shipMatches(ship, filter) then
      local profit, turnover, count = 0, 0, 0
      for _, tx in ipairs(ship.tx) do
        if sta.txMatches(tx, filter) then
          profit = profit + tx.profit
          turnover = turnover + tx.sum
          count = count + 1
        end
      end
      if count > 0 then
        result[#result + 1] = {
          ship = ship, profit = profit, turnover = turnover, count = count,
        }
      end
    end
  end

  if sortBy == "profit" then
    table.sort(result, function(a, b)
      if a.profit == b.profit then
        return a.ship.fullName < b.ship.fullName
      end
      return a.profit > b.profit
    end)
  else
    table.sort(result, function(a, b) return a.ship.fullName < b.ship.fullName end)
  end
  return result
end

function sta.filteredTransactions(ship, filter)
  local result = {}
  for _, tx in ipairs(ship.tx) do
    if sta.txMatches(tx, filter) then
      result[#result + 1] = tx
    end
  end
  return result
end

-- *** aggregates for the ranked views ***

-- Profit per (ship, ware) pair, as { key, name, total, parts = { {name, value} } }
-- rows ready for a stacked bar. groupBy "ship" puts ships on the axis and wares
-- in the segments; "ware" transposes it.
function sta.rankedBreakdown(filter, groupBy, reverse)
  local groups = {}
  local order = {}

  local function bucket(groupKey, groupName, partKey, partName, value)
    local g = groups[groupKey]
    if g == nil then
      g = { key = groupKey, name = groupName, total = 0, parts = {}, partOrder = {} }
      groups[groupKey] = g
      order[#order + 1] = g
    end
    g.total = g.total + value
    local p = g.parts[partKey]
    if p == nil then
      p = { key = partKey, name = partName, value = 0 }
      g.parts[partKey] = p
      g.partOrder[#g.partOrder + 1] = p
    end
    p.value = p.value + value
  end

  for _, ship in ipairs(sta.ships) do
    if sta.shipMatches(ship, filter) then
      for _, tx in ipairs(ship.tx) do
        if sta.txMatches(tx, filter) then
          local ware = sta.getWare(tx.ware)
          if groupBy == "ware" then
            bucket(tx.ware, ware.name, ship.idcode, ship.fullName, tx.profit)
          else
            bucket(ship.idcode, ship.fullName, tx.ware, ware.name, tx.profit)
          end
        end
      end
    end
  end

  table.sort(order, function(a, b)
    if a.total == b.total then
      return a.name < b.name
    end
    return a.total > b.total
  end)
  for _, g in ipairs(order) do
    table.sort(g.partOrder, function(a, b) return a.value > b.value end)
  end

  if reverse then
    local flipped = {}
    for i = #order, 1, -1 do
      flipped[#flipped + 1] = order[i]
    end
    order = flipped
  end
  return order
end

-- Cargo load distribution: one entry per ship with its average and best load
-- percentage across the filtered transactions.
function sta.cargoLoad(filter, reverse)
  local rows = {}
  for _, ship in ipairs(sta.ships) do
    if sta.shipMatches(ship, filter) then
      local sum, count, best = 0, 0, 0
      for _, tx in ipairs(ship.tx) do
        if sta.txMatches(tx, filter) then
          sum = sum + tx.load
          count = count + 1
          if tx.load > best then
            best = tx.load
          end
        end
      end
      if count > 0 then
        rows[#rows + 1] = {
          key = ship.idcode, name = ship.fullName,
          average = sum / count, best = best, count = count,
        }
      end
    end
  end

  table.sort(rows, function(a, b)
    if a.average == b.average then
      return a.name < b.name
    end
    return a.average > b.average
  end)
  if reverse then
    local flipped = {}
    for i = #rows, 1, -1 do
      flipped[#flipped + 1] = rows[i]
    end
    rows = flipped
  end
  return rows
end

-- *** init ***

function sta.init()
  sta.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  sta.onDebugLevelChanged()

  -- Everything this module reads is declared by vanilla rather than here, so a
  -- renamed struct or entry point in a future patch has to fail loudly once at
  -- load instead of on every scan. Indexing ffi.C with an undeclared symbol
  -- raises rather than returning nil, hence the pcall around both checks.
  sta.available = pcall(function()
    ffi.typeof("TransactionLogEntry")
    ffi.typeof("StorageInfo")
    return C.GetNumTransactionLog, C.GetTransactionLog, C.GetNumCargoTransportTypes
  end)
  if not sta.available then
    DebugError("[STA] init: trade-log API not found; the analyzer will show no data.")
  end

  RegisterEvent("ShipsTradeAnalyzer.DebugLevelChanged", sta.onDebugLevelChanged)
  debugLog("init: playerId=%s debugLevel=%s available=%s.",
    tostring(sta.playerId), sta.debugLevel, tostring(sta.available))
end

Register_Require_With_Init("extensions.ships_trade_analyzer.ui.sta_data", sta, sta.init)
