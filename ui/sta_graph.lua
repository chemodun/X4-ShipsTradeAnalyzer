-- Ships Trade Analyzer - sector gate graph.
--
-- Lua has no hop-count call (C.GetDistanceBetween is metric), so MD publishes the
-- galaxy's sector adjacency as { from, to } macro pairs and the BFS runs here.
-- Edges are directed: a superhighway pair can be one-way.

---@diagnostic disable-next-line: unresolved-require
local sta = require("extensions.ships_trade_analyzer.ui.sta_data")

local staGraph = {
  ---@type table<string, string[]>? [fromMacro] = { toMacro, ... }, nil until first load
  adjacency = nil,
  -- [fromMacro] = { [toMacro] = hops }, one cached BFS per source sector
  ---@type table<string, table<string, number>>
  rows = {},
  requested = false,
}

local function buildAdjacency(rawList)
  local adj = {}
  local edges = 0
  for _, entry in ipairs(rawList) do
    local from, to = entry.from, entry.to
    if from ~= nil and to ~= nil then
      local row = adj[from]
      if row == nil then
        row = {}
        adj[from] = row
      end
      row[#row + 1] = to
      edges = edges + 1
    end
  end
  return adj, edges
end

-- A saved graph predates any gate the load itself unlocks, so it is never reused.
local function requestBuild(why)
  staGraph.adjacency = nil
  staGraph.rows = {}
  staGraph.requested = true
  sta.debugLog("graph: %s, requesting a rebuild from MD.", why)
  AddUITriggeredEvent("ShipsTradeAnalyzer", "requestSectorGraph")
end

-- False while MD has not published yet; init already armed the request.
local function ensureLoaded()
  if staGraph.adjacency ~= nil then
    return true
  end

  local rawList = GetNPCBlackboard(sta.playerId, "$ShipsTradeAnalyzerGraph")
  if type(rawList) ~= "table" or #rawList == 0 then
    if not staGraph.requested then
      requestBuild("nothing in the blackboard")
    end
    return false
  end

  local adj, edges = buildAdjacency(rawList)
  staGraph.adjacency = adj
  staGraph.rows = {}
  -- Cleared only here: a rebuild publishing nothing must not re-arm its own request.
  staGraph.requested = false
  sta.debugLog("graph: loaded %d directed edge(s).", edges)
  return true
end

-- Hop counts from one sector to every sector reachable from it.
---@param fromMacro string
---@param adjacency table<string, string[]|nil>
local function bfs(fromMacro, adjacency)
  ---@type table<string, number>
  local dist = { [fromMacro] = 0 }
  ---@type string[]
  local queue = { fromMacro }
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    local next_ = dist[node] + 1
    ---@type string[]|nil
    local neighbours = adjacency[node]
    if neighbours ~= nil then
      for _, to in ipairs(neighbours) do
        if dist[to] == nil then
          dist[to] = next_
          queue[#queue + 1] = to
        end
      end
    end
  end
  return dist
end

-- nil when a macro is unknown or unreachable; the column renders that as a dash.
function staGraph.getJumps(fromMacro, toMacro)
  if fromMacro == nil or toMacro == nil or fromMacro == "" or toMacro == "" then
    return nil
  end
  if fromMacro == toMacro then
    return 0
  end
  if not ensureLoaded() then
    return nil
  end
  local adjacency = staGraph.adjacency
  if adjacency == nil then
    return nil
  end

  local row = staGraph.rows[fromMacro]
  if row == nil then
    if adjacency[fromMacro] == nil then
      return nil
    end
    row = bfs(fromMacro, adjacency)
    staGraph.rows[fromMacro] = row
  end
  return row[toMacro]
end

-- Gates flown to reach each transaction, from where that ship traded last.
function staGraph.fillTransactionJumps()
  if not ensureLoaded() then
    sta.debugLog("graph: no adjacency yet, transaction jumps stay unresolved.")
    return
  end
  local resolved, total = 0, 0
  for _, ship in ipairs(sta.ships) do
    for _, tx in ipairs(ship.tx) do
      tx.jumps = staGraph.getJumps(tx.prevSecMacro, tx.pSecMacro)
      total = total + 1
      if tx.jumps ~= nil then
        resolved = resolved + 1
      end
    end
  end
  sta.debugLog("graph: jumps resolved for %d of %d transaction(s).", resolved, total)
end

function staGraph.onSectorGraphReady()
  staGraph.adjacency = nil
  staGraph.rows = {}
  sta.debugLog("graph: MD reports a new sector graph, dropping the cached one.")
  -- A scan that ran before the graph arrived left every transaction unresolved and
  -- every injected leg dated mid-gap.
  if sta.scanned then
    sta.retimeInjected()
    staGraph.fillTransactionJumps()
  end
end

function staGraph.init()
  sta.afterScan = staGraph.fillTransactionJumps
  sta.jumpsBetween = staGraph.getJumps
  RegisterEvent("ShipsTradeAnalyzer.SectorGraphReady", staGraph.onSectorGraphReady)
  requestBuild("game loaded")
end

Register_Require_With_Init("extensions.ships_trade_analyzer.ui.sta_graph", staGraph, staGraph.init)
