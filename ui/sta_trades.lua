-- Ships Trade Analyzer - completed-trade pairing.
--
-- Turns a ship's flat transaction list into completed trades (buy legs matched
-- against the sell legs that emptied them again), so profit is real rather than
-- estimated against the ware's average price. Port of GetFullTrades from
-- X4PlayerShipTradeAnalyzer (Models/FullTrade.cs), same segmenting rules.
--
-- A segment runs per ship and per ware, opens on a buy, and closes when the
-- accumulated volume returns to zero. A buy arriving after selling has started
-- closes the current segment and opens a new one; an unbalanced segment is
-- dropped rather than reported.

local sta = require("extensions.ships_trade_analyzer.ui.sta_data")

local staTrades = {}

local function makeLeg(tx, volume)
  return {
    t       = tx.t,
    vol     = volume,
    price   = tx.price,
    station = tx.pName,
    sector  = tx.pSector,
    owner   = tx.pOwner,
  }
end

local function allPlayerOwned(legs)
  for _, leg in ipairs(legs) do
    if leg.owner ~= "player" then
      return false
    end
  end
  return #legs > 0
end

local function buildForShip(ship)
  local trades = {}

  local currentWare ---@type string?
  local trade ---@type table?
  local inSegment    = false
  local sellingStarted = false
  local cumVolume    = 0
  local purchases    = {}
  local sales        = {}

  local function reset()
    inSegment = false
    sellingStarted = false
    cumVolume = 0
    purchases = {}
    sales = {}
    trade = nil
  end

  local function finish()
    if trade ~= nil and trade.bought > 0 and trade.sold > 0 then
      -- More bought than sold: keep only the newest purchases that the sales
      -- actually cleared, so the reported buy cost matches the sold volume.
      if trade.bought > trade.sold then
        local kept, bought, cost = {}, 0, 0
        for i = #purchases, 1, -1 do
          if bought >= trade.sold then
            break
          end
          table.insert(kept, 1, purchases[i])
          bought = bought + purchases[i].vol
          cost = cost + purchases[i].vol * purchases[i].price
        end
        if bought ~= trade.sold then
          reset()
          return
        end
        purchases = kept
        trade.bought = bought
        trade.buyCost = cost
        trade.startTime = purchases[1].t
      end

      if trade.bought == trade.sold then
        local ware = sta.getWare(trade.ware)
        local capacity = ship.capacity[ware.transport]
        local hasCapacity = (capacity ~= nil and capacity > 0 and ware.volume > 0)
        local maxQuantity = hasCapacity and (capacity / ware.volume) or 0

        trade.purchases = purchases
        trade.sales     = sales
        trade.profit    = trade.revenue - trade.buyCost
        trade.duration  = math.max(0, trade.endTime - trade.startTime)
        trade.load      = (maxQuantity > 0) and math.min(100, trade.bought / maxQuantity * 100) or 100
        trade.internal  = allPlayerOwned(purchases) and allPlayerOwned(sales)
        trades[#trades + 1] = trade
      end
    end
    reset()
  end

  for _, tx in ipairs(ship.tx) do
    if tx.ware ~= currentWare or (inSegment and not tx.sale and sellingStarted) then
      finish()
      currentWare = tx.ware
    end

    if not inSegment then
      if not tx.sale then
        trade = {
          ware      = tx.ware,
          startTime = tx.t,
          endTime   = tx.t,
          bought    = tx.vol,
          sold      = 0,
          buyCost   = tx.price * tx.vol,
          revenue   = 0,
        }
        inSegment = true
        cumVolume = tx.vol
        purchases[#purchases + 1] = makeLeg(tx, tx.vol)
      end
    else
      if not tx.sale then
        cumVolume = cumVolume + tx.vol
        trade.endTime = tx.t
        trade.bought  = trade.bought + tx.vol
        trade.buyCost = trade.buyCost + tx.price * tx.vol
        purchases[#purchases + 1] = makeLeg(tx, tx.vol)
      else
        sellingStarted = true
        local soldNow = math.min(tx.vol, math.max(0, cumVolume))
        if soldNow > 0 then
          cumVolume = cumVolume - soldNow
          trade.endTime = tx.t
          trade.sold    = trade.sold + soldNow
          trade.revenue = trade.revenue + tx.price * soldNow
          sales[#sales + 1] = makeLeg(tx, soldNow)
        end
      end

      if cumVolume == 0 and trade.bought > 0 and trade.sold > 0 then
        finish()
      end
    end
  end

  -- A segment still holding cargo is deliberately not emitted: its profit is
  -- not known until the rest is sold.
  return trades
end

-- Cached on the ship record: the pairing only depends on the scan, and every
-- filter that applies to trades is applied afterwards.
function staTrades.getTrades(ship)
  if ship.trades == nil then
    ship.trades = buildForShip(ship)
    sta.traceLog("getTrades: %s produced %d completed trade(s) from %d transaction(s).",
      ship.fullName, #ship.trades, #ship.tx)
  end
  return ship.trades
end

function staTrades.filteredTrades(ship, filter)
  local result = {}
  for _, trade in ipairs(staTrades.getTrades(ship)) do
    local passes = true
    if not filter.internalTrades and trade.internal then
      passes = false
    end
    if passes and filter.cargoType ~= "all" and sta.getWare(trade.ware).transport ~= filter.cargoType then
      passes = false
    end
    if passes then
      result[#result + 1] = trade
    end
  end
  return result
end

-- Ships passing the filter with their completed-trade totals, sorted the same
-- way sta.filteredShips sorts the transaction view.
function staTrades.filteredShips(filter, sortBy)
  local result = {}
  for _, ship in ipairs(sta.ships) do
    if sta.shipMatches(ship, filter) then
      local profit, revenue, count = 0, 0, 0
      for _, trade in ipairs(staTrades.filteredTrades(ship, filter)) do
        profit = profit + trade.profit
        revenue = revenue + trade.revenue
        count = count + 1
      end
      if count > 0 then
        result[#result + 1] = { ship = ship, profit = profit, turnover = revenue, count = count }
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

-- Ranked breakdown over completed trades, mirroring sta.rankedBreakdown's shape
-- so the ranked views can render either analysis mode from one code path.
function staTrades.rankedBreakdown(filter, groupBy, reverse)
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
      for _, trade in ipairs(staTrades.filteredTrades(ship, filter)) do
        local ware = sta.getWare(trade.ware)
        if groupBy == "ware" then
          bucket(trade.ware, ware.name, ship.key, ship.fullName, trade.profit)
        else
          bucket(ship.key, ship.fullName, trade.ware, ware.name, trade.profit)
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

-- Load distribution over completed trades: how full the ship actually ran.
function staTrades.cargoLoad(filter, reverse)
  local rows = {}
  for _, ship in ipairs(sta.ships) do
    if sta.shipMatches(ship, filter) then
      local sum, count, best = 0, 0, 0
      for _, trade in ipairs(staTrades.filteredTrades(ship, filter)) do
        sum = sum + trade.load
        count = count + 1
        if trade.load > best then
          best = trade.load
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

Register_Require_Response("extensions.ships_trade_analyzer.ui.sta_trades", staTrades)
