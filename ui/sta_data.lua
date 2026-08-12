-- Ships Trade Analyzer - data layer.
--
-- Reads the engine's trade log per player-owned ship and turns it into per-ship
-- transaction lists plus the aggregates the menu views need. Nothing is sampled
-- or persisted; the log already lives in the save.
--
-- The transaction-log and cargo entry points and their structs are declared by
-- vanilla with identical layouts in 8.00 and 9.00, so they are taken from the
-- shared ffi namespace rather than re-declared here.

---@diagnostic disable-next-line: unresolved-require
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
  -- False if the borrowed vanilla names are gone; every scan then no-ops.
  available  = false,

  ships       = {},  -- array of ship records, see buildShip()
  wareCache   = {},  -- [wareId] = { name, transport, volume, avgprice }
  sectorOwner = {},  -- [sectorid] = owner faction id, "" when unowned
  sectorMacro = {},  -- [sectorid] = macro name, the key sta_graph joins on
  stationInfo = {},  -- [station key] = the home station as a counterpart record
  stationPrice = {}, -- [station key] = { buy = {}, sell = {} }, current offer prices
  widestWareName = "", -- "" if the ware list was unreadable at init

  scanTime      = 0, -- game time the last scan ran at
  -- What a memo keys on: two scans can share a game second, scanTime cannot tell them apart.
  scanCount     = 0,
  scanned       = false,
  totalEntries  = 0, -- trade entries kept across every ship
  skippedShips  = 0, -- ships whose log exceeded maxEntriesPerShip
  injectedEntries = 0, -- home-station legs invented across every ship

  -- The engine logs no trade between a player station and a player ship; off shows
  -- the log raw, on reconstructs the missing half.
  injectInternal = true,
  -- Two same-way trades of one ware further apart than this are separate trips;
  -- the Options value in seconds, resolved once per scan.
  multiHopSeconds = 600,
}

local config = {
  -- Oldest entries past this are dropped, so a long save cannot blow the Lua heap.
  maxEntriesPerShip = 5000,
  -- No usable per-unit volume against ship capacity, so their load reads as full.
  fullLoadWares = { rawscrap = true },
  -- The only transports a ship carries, and so the only names the Ware column fits.
  wareColumnTransports = { container = true, solid = true, liquid = true, gas = true },
  -- Fallback for a missing Options key; 0 means rescan on every menu open.
  rescanIntervalMinutes = 1,
  -- Fallback for a missing Options key, in minutes.
  internalSeparationMinutes = 10,
}

-- *** debug helpers ***

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

-- The Options separation period in seconds; stored in minutes like the slider shows it.
local function separationSeconds(cfg)
  local minutes = tonumber((cfg or sta.getConfig()).timePeriodForInternalTradesSeparation)
      or config.internalSeparationMinutes
  return minutes * 60
end

-- *** formatting (local: both vanilla equivalents are 9.00-only) ***

-- The tier is picked on the seconds, never on the rendered string: two tiers that
-- match in English need not in another language.
local function formatTiered(seconds, below1h, below1d, above1d)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local id
  if seconds < 3600 then
    id = below1h
  elseif seconds < 86400 then
    id = below1d
  else
    id = above1d
  end
  return ConvertTimeString(seconds, ReadText(1001, id))
end

-- A span; the tiers Helper.getPassedTimeShort uses.
function sta.formatDuration(seconds)
  return formatTiered(seconds, 210, 207, 205)
end

-- Time since; Helper.getPassedTime's tiers, which carry vanilla's "ago".
function sta.formatAgo(t, now)
  return formatTiered((now or sta.scanTime) - t, 213, 212, 211)
end

function sta.formatMoney(value)
  return ConvertMoneyString(math.floor(value + 0.5), false, true, 0, true) .. " " .. ReadText(1001, 101)
end

-- A per-unit price is in hundredths of a credit; 1001,105 is the decimal point,
-- which is a comma in several languages.
function sta.formatPrice(value)
  local cents = math.floor(math.abs(value) * 100 + 0.5)
  local whole = math.floor(cents / 100)
  return ((value < 0) and "-" or "") ..
      ConvertMoneyString(whole, false, true, 0, true) ..
      ReadText(1001, 105) .. string.format("%02d", cents - whole * 100) ..
      " " .. ReadText(1001, 101)
end

function sta.factionColor(owner)
  if owner == nil or owner == "" then
    return nil
  end
  return GetFactionData(owner, "color")
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
  local factioncolor = sta.factionColor(faction)
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

-- Largest first; IsComponentClass is the only way to a size class, "class" is not
-- a GetComponentData key.
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

-- Station the ship reports to, up the commander chain. Returns it as a UniverseID,
-- the form buyerid/sellerid arrive in, so a relation is a direct comparison.
local function parentStation(luaId, label)
  local tracing = sta.debugLevel == "trace"
  local current = GetCommander(luaId)
  for hop = 1, 8 do
    if current == nil or current == 0 then
      if tracing then
        traceLog("parentStation: %s no commander at hop %d.", label, hop)
      end
      return nil, nil, nil
    end
    local isStation = IsComponentClass(current, "station")
    -- Only paid for when it is the answer, or when trace asked.
    if isStation or tracing then
      local name, idcode, classId = GetComponentData(current, "name", "idcode", "classid")
      if tracing then
        traceLog("parentStation: %s hop %d commander %s (%s), classid %s, station %s.",
          label, hop, name or "?", idcode or "?", classId or "?", tostring(isStation))
      end
      if isStation then
        return ConvertIDTo64Bit(current), name, idcode
      end
    end
    current = GetCommander(current)
  end
  if tracing then
    traceLog("parentStation: %s depth cap reached, no station in the chain.", label)
  end
  return nil, nil, nil
end

-- Faction holding the sector, which is not the station's own owner. Cached: the
-- scan walks tens of thousands of transactions over a handful of sectors.
local function sectorOwnerOf(sectorId)
  if sectorId == nil or sectorId == 0 then
    return ""
  end
  local owner = sta.sectorOwner[sectorId]
  if owner == nil then
    owner = GetComponentData(sectorId, "owner") or ""
    sta.sectorOwner[sectorId] = owner
  end
  return owner
end

-- The string MD's $sector.macro produces, and so the only key sta_graph can join
-- on. Cached like the owner above.
local function sectorMacroOf(sectorId)
  if sectorId == nil or sectorId == 0 then
    return ""
  end
  local macro = sta.sectorMacro[sectorId]
  if macro == nil then
    macro = GetComponentData(sectorId, "macro") or ""
    sta.sectorMacro[sectorId] = macro
  end
  return macro
end

-- *** counterpart resolution ***

-- Whichever side of the entry is not this ship. Falls back to the entry's own
-- partner strings when the component is gone, so a destroyed station still reads.
local function counterpartInfo(otherId, entryPartnerName, entryPartnerIdcode)
  local info = { name = "", idcode = "", owner = "", sector = "", sectorOwner = "",
    sectorMacro = "", icon = "", luaId = nil }
  if otherId ~= nil and otherId ~= 0 and C.IsComponentOperational(otherId) then
    local luaId = ConvertStringToLuaID(tostring(otherId))
    local name, idcode, owner, sector, sectorId, icon =
        GetComponentData(luaId, "name", "idcode", "owner", "sector", "sectorid", "icon")
    info.luaId  = luaId
    info.name   = name or ""
    info.idcode = idcode or ""
    info.owner  = owner or ""
    info.sector = sector or ""
    info.icon   = icon or ""
    info.sectorOwner = sectorOwnerOf(sectorId)
    info.sectorMacro = sectorMacroOf(sectorId)
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

-- Container wares are measured against the ware's average price, so a purchase
-- below it already books profit. Mined goods have no such reference: the sale is.
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

-- No usable per-unit volume against the ship's capacity reads as a full load.
local function loadPercent(ship, wareId, ware, used)
  local capacity = ship.capacity[ware.transport]
  if config.fullLoadWares[wareId] or capacity == nil or capacity <= 0 then
    return 100
  end
  return math.min(100, used / capacity * 100)
end

-- What it took to reach each stop - gates and time both - measured against the
-- previous stop of the whole log, not of a filtered view: the route flown.
local function linkPrevious(ship)
  for i = 2, #ship.tx do
    ship.tx[i].prevSecMacro = ship.tx[i - 1].pSecMacro
    ship.tx[i].duration = math.max(0, ship.tx[i].t - ship.tx[i - 1].t)
  end
end

local function readShipLog(ship, startTime, endTime)
  local id64 = ship.id64
  local total = tonumber(C.GetNumTransactionLog(id64, startTime, endTime)) or 0
  if total <= 0 then
    return
  end

  local buf = ffi.new("TransactionLogEntry[?]", total)
  total = tonumber(C.GetTransactionLog(buf, total, id64, startTime, endTime)) or 0

  -- Oldest first, so a capped ship still shows its most recent trading.
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
          -- Helper.createTransactionLog's test: trust an explicit seller id, else
          -- the sign of the money change.
          local isSale = (sellerId ~= 0 and sellerId == id64) or (sellerId == 0 and money >= 0)
          local otherId = isSale and buf[i].buyerid or sellerId
          local partner = counterpartInfo(otherId,
            ffi.string(buf[i].partnername), ffi.string(buf[i].partneridcode))

          local ware = sta.getWare(wareId)
          local sum  = price * amount
          local used = amount * ware.volume

          local tx = {
            t        = tonumber(buf[i].time) or 0,
            sale     = isSale,
            ware     = wareId,
            price    = price,
            vol      = amount,
            sum      = sum,
            profit   = estimateProfit(ware, isSale, sum, amount),
            used     = used,
            load     = loadPercent(ship, wareId, ware, used),
            pName    = displayName(partner.name, partner.idcode),
            pOwner   = partner.owner,
            pSector  = partner.sector,
            pSecOwner = partner.sectorOwner,
            pSecMacro = partner.sectorMacro,
            pIcon    = partner.icon,
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

  -- The engine returns entries newest-first in places; pairing and the graph both
  -- assume ascending time.
  table.sort(ship.tx, function(a, b) return a.t < b.t end)
  traceLog("readShipLog: %s kept %d trade entries.", ship.fullName, #ship.tx)
end

-- *** the internal legs the engine never logs ***

-- The home station as a counterpart record, cached: one station commands many ships.
local function homeInfo(ship)
  local info = sta.stationInfo[ship.stationKey]
  if info == nil then
    info = counterpartInfo(ship.stationId, ship.stationName, "")
    sta.stationInfo[ship.stationKey] = info
  end
  return info
end

-- The station buys what the ship sells. False when that side's price is automatic:
-- it moves with the stock, so what it was at the time of the leg is unknowable.
local function homePrice(ship, home, wareId, isSale)
  local prices = sta.stationPrice[ship.stationKey]
  if prices == nil then
    prices = { buy = {}, sell = {} }
    sta.stationPrice[ship.stationKey] = prices
  end
  local side = isSale and prices.buy or prices.sell
  local price = side[wareId]
  if price == nil then
    price = false
    if home.luaId ~= nil then
      local ok, override = pcall(HasContainerWarePriceOverride, home.luaId, wareId, isSale)
      if ok and override then
        local got, value = pcall(GetContainerWarePrice, home.luaId, wareId, isSale)
        price = got and tonumber(value) or false
      end
    end
    side[wareId] = price
    traceLog("homePrice: %s %s %s price is %s.", ship.stationName or "?", wareId,
      isSale and "buy" or "sell", price and tostring(price) or "automatic")
  end
  return price
end

-- The gap split by the gates flown either side. No jump counts as half a hop, which
-- is what lands a stop in both sectors - or one the graph cannot place - mid-gap.
local function internalTime(previous, following, homeMacro)
  local share = 0.5
  if sta.jumpsBetween ~= nil then
    local before = sta.jumpsBetween(previous.pSecMacro, homeMacro)
    local after  = sta.jumpsBetween(homeMacro, following.pSecMacro)
    if before ~= nil and after ~= nil then
      before = (before > 0) and before or 0.5
      after  = (after > 0) and after or 0.5
      share  = before / (before + after)
    end
  end
  return previous.t + (following.t - previous.t) * share
end

-- nil when the station prices the ware automatically: nothing is invented then.
local function internalEntry(ship, home, previous, following, isSale, volume)
  local wareId = following.ware
  local price  = homePrice(ship, home, wareId, isSale)
  if not price then
    return nil
  end
  local ware = sta.getWare(wareId)
  local sum  = price * volume
  local used = volume * ware.volume
  return {
    t        = internalTime(previous, following, home.sectorMacro),
    sale     = isSale,
    ware     = wareId,
    price    = price,
    vol      = volume,
    sum      = sum,
    profit   = estimateProfit(ware, isSale, sum, volume),
    used     = used,
    load     = loadPercent(ship, wareId, ware, used),
    pName    = displayName(home.name, home.idcode),
    pOwner   = home.owner,
    pSector  = home.sector,
    pSecOwner = home.sectorOwner,
    pSecMacro = home.sectorMacro,
    pIcon    = home.icon,
    pLuaId   = home.luaId,
    internal = true,
  }
end

-- What the hold takes of the ware, 0 when the ship's capacity for it is unknown.
local function unitCapacity(ship, ware)
  local capacity = ship.capacity[ware.transport]
  if capacity == nil or capacity <= 0 or ware.volume <= 0 then
    return 0
  end
  return capacity / ware.volume
end

-- One visit home supplies the whole run of sales that follows, so this reaches
-- forward to the next purchase, to the hold's limit, or to a gap too long for a trip.
local function shortfall(ship, entries, index, wareId, ware, held)
  local maxUnits = unitCapacity(ship, ware)
  -- Nothing bounds the scan without a capacity either.
  if maxUnits <= 0 then
    return entries[index].vol - held
  end
  local wanted, last = 0, nil
  for i = index, #entries do
    local tx = entries[i]
    if tx.ware == wareId then
      if not tx.sale or (last ~= nil and tx.t - last > sta.multiHopSeconds) then
        break
      end
      wanted, last = wanted + tx.vol, tx.t
      if wanted >= maxUnits then
        wanted = maxUnits
        break
      end
    end
  end
  return wanted - held
end

-- Cargo the ship cannot account for gives a home stop away: a sale larger than it
-- holds was loaded there, a purchase it has no room for was preceded by unloading.
local function injectForShip(ship)
  local home = homeInfo(ship)
  local merged, onboard, lastBuy, added = {}, {}, {}, 0

  for index, tx in ipairs(ship.tx) do
    local ware = sta.getWare(tx.ware)
    local held = onboard[tx.ware] or 0
    local isSale, volume
    if tx.sale then
      local missing = shortfall(ship, ship.tx, index, tx.ware, ware, held)
      if missing > 0 then
        isSale, volume = false, missing
      end
    elseif held > 0 then
      local maxUnits = unitCapacity(ship, ware)
      local since = lastBuy[tx.ware]
      if (maxUnits > 0 and held + tx.vol > maxUnits)
          or (since ~= nil and tx.t - since > sta.multiHopSeconds) then
        isSale, volume = true, held
      end
    end

    local previous = merged[#merged]
    if volume ~= nil then
      -- The cargo moved even where the leg cannot be priced or dated; not tracking
      -- it would invent a second visit later in the run.
      onboard[tx.ware] = isSale and 0 or (held + volume)
      local entry = previous and internalEntry(ship, home, previous, tx, isSale, volume)
      if entry then
        merged[#merged + 1] = entry
        ship.profit   = ship.profit + entry.profit
        ship.turnover = ship.turnover + entry.sum
        added = added + 1
      end
    end

    merged[#merged + 1] = tx
    if tx.sale then
      onboard[tx.ware] = math.max(0, (onboard[tx.ware] or 0) - tx.vol)
    else
      onboard[tx.ware] = (onboard[tx.ware] or 0) + tx.vol
      lastBuy[tx.ware] = tx.t
    end
  end

  if added > 0 then
    ship.tx = merged
    sta.injectedEntries = sta.injectedEntries + added
    traceLog("injectForShip: %s gained %d leg(s) at %s.", ship.fullName, added, ship.stationName)
  end
end

-- A graph arriving after the scan leaves every leg dated mid-gap. Safe in place: a
-- new time stays inside the gap, so the order holds - but the paired trades do not.
function sta.retimeInjected()
  if sta.jumpsBetween == nil then
    return
  end
  local moved = 0
  for _, ship in ipairs(sta.ships) do
    local shipMoved = 0
    for i = 2, #ship.tx - 1 do
      local tx = ship.tx[i]
      if tx.internal then
        tx.t = internalTime(ship.tx[i - 1], ship.tx[i + 1], tx.pSecMacro)
        shipMoved = shipMoved + 1
      end
    end
    if shipMoved > 0 then
      -- A moved entry changes the gap either side of it.
      linkPrevious(ship)
      ship.trades = nil
      moved = moved + shipMoved
    end
  end
  debugLog("retimeInjected: re-dated %d internal leg(s).", moved)
end

local function buildShip(luaId)
  local name, idcode, sector, icon = GetComponentData(luaId, "name", "idcode", "sector", "icon")
  local classId = shipClassOf(luaId)
  local fullName = displayName(name, idcode)
  local stationId, stationName, stationIdcode = parentStation(luaId, fullName)
  local id64 = ConvertIDTo64Bit(luaId)
  return {
    luaId       = luaId,
    id64        = id64,
    -- For the places a 64-bit id cannot go: table keys (LuaJIT hashes cdata by
    -- identity, not value), row data and dropdown ids.
    key         = tostring(id64),
    name        = name or "",
    fullName    = fullName,
    classId     = classId or "",
    icon        = icon or "",
    sector      = sector or "",
    stationId   = stationId,
    stationKey  = stationId and tostring(stationId) or nil,
    stationName = stationId and displayName(stationName, stationIdcode) or nil,
    capacity    = cargoCapacities(id64),
    tx          = {},
    profit      = 0,
    turnover    = 0,
  }
end

-- Vanilla's isObjectValid test: drones, deployables, wrecks and limpets are all
-- "ship" class. The class test comes first to save the component lookup.
local function isListableShip(luaId)
  if not IsComponentClass(luaId, "ship") or IsComponentClass(luaId, "spacesuit") then
    return false
  end
  local isdeployable, isunit, iswreck, isattachedaslimpet =
      GetComponentData(luaId, "isdeployable", "isunit", "iswreck", "isattachedaslimpet")
  return not (isdeployable or isunit or iswreck or isattachedaslimpet)
end

function sta.scan()
  if not sta.available then
    debugLog("scan: trade-log API unavailable, nothing to do.")
    return
  end

  local now = C.GetCurrentGameTime()

  sta.ships = {}
  sta.totalEntries = 0
  sta.skippedShips = 0
  sta.injectedEntries = 0
  sta.scanTime = now
  sta.scanCount = sta.scanCount + 1
  sta.multiHopSeconds = separationSeconds()
  sta.sectorOwner = {} -- sectors change hands; only cache within a scan
  sta.sectorMacro = {} -- a macro never changes, but the ids keying it go stale
  sta.stationInfo = {} -- a station moves sector and reprices between scans
  sta.stationPrice = {}

  -- Every listable ship is kept, traded or not; the withTransactions filter is
  -- what narrows the views, and the station options derive from the same set.
  local tradingShips, shipsWithStation = 0, 0
  local objects = GetContainedObjectsByOwner("player")
  for _, luaId in ipairs(objects) do
    if isListableShip(luaId) then
      local ship = buildShip(luaId)
      readShipLog(ship, 0, now)
      if sta.injectInternal and ship.stationId ~= nil then
        injectForShip(ship)
      end
      linkPrevious(ship)
      sta.ships[#sta.ships + 1] = ship
      if #ship.tx > 0 then
        tradingShips = tradingShips + 1
      end
      if ship.stationKey ~= nil then
        shipsWithStation = shipsWithStation + 1
      end
    end
  end

  sta.scanned = true
  debugLog("scan: %d ship(s), %d trading, %d trade entries, %d under a station, %d internal leg(s).",
    #sta.ships, tradingShips, sta.totalEntries, shipsWithStation, sta.injectedEntries)

  -- sta_graph installs its jump pass here; it requires this module, not the other way.
  if sta.afterScan ~= nil then
    sta.afterScan()
  end
end

-- Scans when there is no snapshot or it aged past the configured interval. True
-- when one ran: anything the caller keyed on the previous snapshot is stale.
function sta.ensureScanned()
  local cfg = sta.getConfig()
  -- The separation period shapes the injected legs, so a change to it invalidates
  -- the snapshot however young it is.
  if sta.scanned and separationSeconds(cfg) == sta.multiHopSeconds then
    local minutes = tonumber(cfg.rescanIntervalMinutes)
        or config.rescanIntervalMinutes
    if C.GetCurrentGameTime() - sta.scanTime < minutes * 60 then
      return false
    end
  end
  sta.scan()
  return true
end

-- *** filtering ***

function sta.defaultFilter()
  return {
    withTransactions = true,
    parentStation  = "any",   -- "any" | "none" | <station id as a string>
    shipClass      = "all",   -- "all" | ship_xl | ship_l | ship_m | ship_s
    cargoType      = "all",   -- "all" | container | solid | liquid | gas
  }
end

-- The stations of exactly the ships the views show, so an option is never empty.
-- Memoised on the one filter field it depends on: the dropdown rebuilds per frame.
function sta.stationOptions(filter)
  local key = tostring(filter.withTransactions) .. "|" .. tostring(sta.scanCount)
  if sta.stationOptionsKey ~= key then
    local list, seen = {}, {}
    for _, ship in ipairs(sta.ships) do
      if ship.stationKey ~= nil and not seen[ship.stationKey]
          and (#ship.tx > 0 or not filter.withTransactions) then
        seen[ship.stationKey] = true
        list[#list + 1] = { id = ship.stationId, key = ship.stationKey, name = ship.stationName }
      end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    sta.stationOptionsCache = list
    sta.stationOptionsKey = key
    traceLog("stationOptions: %d station(s) for withTransactions %s.", #list, tostring(filter.withTransactions))
  end
  return sta.stationOptionsCache
end

-- A station picked with every ship listed need not survive narrowing to traders.
function sta.stationOffered(filter, key)
  if key == "any" or key == "none" then
    return true
  end
  for _, station in ipairs(sta.stationOptions(filter)) do
    if station.key == key then
      return true
    end
  end
  return false
end

function sta.shipMatches(ship, filter)
  if filter.withTransactions and #ship.tx == 0 then
    return false
  end
  if filter.shipClass ~= "all" and ship.classId ~= filter.shipClass then
    return false
  end
  if filter.parentStation == "none" then
    return ship.stationId == nil
  elseif filter.parentStation ~= "any" then
    return ship.stationKey == filter.parentStation
  end
  return true
end

function sta.txMatches(tx, filter)
  if filter.cargoType ~= "all" and sta.getWare(tx.ware).transport ~= filter.cargoType then
    return false
  end
  return true
end

-- Ships passing the filter, totalled over only the transactions that pass it too.
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
      -- With the filter off a ship earns its row by existing, not by having trades.
      if count > 0 or not filter.withTransactions then
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

-- Profit per (ship, ware) pair as stacked-bar rows: { key, name, total, parts }.
-- groupBy "ship" puts ships on the axis and wares in the segments, "ware" transposes.
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
            bucket(tx.ware, ware.name, ship.key, ship.fullName, tx.profit)
          else
            bucket(ship.key, ship.fullName, tx.ware, ware.name, tx.profit)
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

-- One entry per ship with its average and best load across the filtered transactions.
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
          key = ship.key, name = ship.fullName,
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

-- Widest tradeable ware name: the Ware column has to fit anything that can turn up
-- in a log, not just what this save traded. "" leaves the column variable.
local function findWidestWareName()
  local widest, widestWidth = "", 0
  local ok = pcall(function()
    local n = C.GetNumWares("economy", false, "", "")
    local buf = ffi.new("const char*[?]", n)
    n = C.GetWares(buf, n, "economy", false, "", "")
    local fontsize = Helper.scaleFont(Helper.standardFont, Helper.standardFontSize)
    for i = 0, n - 1 do
      local ware = sta.getWare(ffi.string(buf[i]))
      if config.wareColumnTransports[ware.transport] then
        local width = C.GetTextWidth(ware.name, Helper.standardFont, fontsize)
        if width > widestWidth then
          widest, widestWidth = ware.name, width
        end
      end
    end
  end)
  if not ok then
    return ""
  end
  return widest
end

function sta.init()
  sta.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  sta.onDebugLevelChanged()
  -- Runs on every game load, and a snapshot belongs to the game it was taken in.
  sta.scanned = false

  -- Indexing ffi.C with an undeclared symbol raises rather than returning nil, so
  -- the borrowed names are proven here once instead of on every scan.
  sta.available = pcall(function()
    ffi.typeof("TransactionLogEntry")
    ffi.typeof("StorageInfo")
    return C.GetNumTransactionLog, C.GetTransactionLog, C.GetNumCargoTransportTypes
  end)
  if not sta.available then
    DebugError("[STA] init: trade-log API not found; the analyzer will show no data.")
  end

  sta.widestWareName = findWidestWareName()

  RegisterEvent("ShipsTradeAnalyzer.DebugLevelChanged", sta.onDebugLevelChanged)
  debugLog("init: playerId=%s debugLevel=%s available=%s widestWare=%q.",
    tostring(sta.playerId), sta.debugLevel, tostring(sta.available), sta.widestWareName)
end

Register_Require_With_Init("extensions.ships_trade_analyzer.ui.sta_data", sta, sta.init)
