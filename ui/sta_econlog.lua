-- Ships Trade Analyzer - the engine's economy trade log (the save's <entries type="trade">), read through
-- Extra UI API's GetEconomyTradeLog.

local econlog = {
  detected = false,
  -- "found" | "missing" | "unknown" (not searched: option off, no game or no trade logged yet)
  state = "unknown",
  reason = "not run",
}

local function api()
  return type(ExtraUI) == "table" and type(ExtraUI.GetEconomyTradeLog) == "function"
end

local function noTrade() end

-- At Lua init; the log is located only while the option is on.
function econlog.detect(enabled)
  econlog.detected = false
  econlog.state = "unknown"
  if not api() then
    econlog.state = "missing"
    econlog.reason = "Extra UI API 1.04 or newer missing"
    return false
  end
  if not enabled then
    econlog.reason = "option off"
    return false
  end
  -- a window after every trade reads none
  local read, why = ExtraUI.GetEconomyTradeLog(noTrade, math.huge)
  if read then
    econlog.state, econlog.detected, econlog.reason = "found", true, "found"
  else
    econlog.state = why == "not ready" and "unknown" or "missing"
    econlog.reason = tostring(why)
  end
  return econlog.detected
end

-- Calls onTrade(time, wareId, buyerId, sellerId, priceCents, amount) oldest first;
-- ids are numbers, 0 when the side is empty. Returns the count read and skipped.
function econlog.readTrades(onTrade)
  if not econlog.detected then return 0, 0 end
  local read, skipped = ExtraUI.GetEconomyTradeLog(onTrade)
  if not read then
    econlog.detected = false
    econlog.state = skipped == "not ready" and "unknown" or "missing"
    econlog.reason = tostring(skipped)
    return 0, 0
  end
  return read, skipped
end

Register_Require_Response("extensions.ships_trade_analyzer.ui.sta_econlog", econlog)

return econlog
