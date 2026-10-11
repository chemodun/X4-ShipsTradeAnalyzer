-- Ships Trade Analyzer - the engine's economy trade log (the save's <entries type="trade">).
--
-- No API exposes it, so it is read from engine memory: the log singleton is found
-- through its "economylog" load site in the running exe, the trade list offset is
-- read from the code that appends to it, and every object followed is checked
-- against a vtable resolved from the exe's own RTTI. The log itself has no vtable.
-- The ware id offset differs between 8.00 and 9.00 and is decided from data.
-- Layout and evidence: claude/task-trade-log-read.md.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local bit = require("bit")

local P = ffi.typeof("uint8_t*")
local FNV_PRIME = ffi.new("uint64_t", 0x1000193)

local econlog = {
  detected = false,
  reason = "not run",
}

-- bumped when the record's meaning changes: older records are searched again
local RECORD_VERSION = 2

local layout = {
  trades = nil, -- std::deque<TradeEntry*> in the economy log, read from code
  entryTime = 0x00, entryWare = 0x10, entryBuyer = 0x18, entrySeller = 0x28,
  entryPrice = 0x38, entryAmount = 0x40,
  objectId = 0x08, -- LogObject: the component's UniverseID
  wareId = nil, wareHash = nil, -- WareClass, per build from wareLayouts
}

-- WareClass id as std::string; hash = its FNV hash, 0 when the build stores none
local wareLayouts = {
  { id = 0x10, hash = 0x08 }, -- 9.00
  { id = 0x08, hash = 0 }, -- 8.00: XLib::DBDataItem base, strings at +0x08, +0x28, +0x48
}

local function u16(p) return ffi.cast("uint16_t*", p)[0] end
local function u32(p) return ffi.cast("uint32_t*", p)[0] end
local function i32(p) return ffi.cast("int32_t*", p)[0] end
local function u64(p) return ffi.cast("uint64_t*", p)[0] end

-- false in bytes matches any byte
local function match(p, bytes)
  for k = 1, #bytes do
    if bytes[k] and p[k - 1] ~= bytes[k] then return false end
  end
  return true
end

local USER_LOW = ffi.new("uint64_t", 0x10000)
local USER_HIGH = ffi.new("uint64_t", 0x7fff00000000)

-- A heap pointer worth dereferencing: user range and allocator alignment.
local function plausible(p, align)
  return p >= USER_LOW and p < USER_HIGH and p % (align or 8) == 0
end

local function hex(n) return string.format("0x%x", tonumber(n)) end

-- The exe image and its sections as RVA ranges: to = the file-backed part (scanned),
-- vto = the whole section (zeroed tail included, where globals live).
local function mapImage()
  -- the walk below the image would read unmapped memory in the native Linux build
  if ffi.os ~= "Windows" then return nil, "not the Windows build" end
  local a = ffi.cast("uintptr_t", ffi.C.GetPlayerID)
  a = a - a % 0x10000
  local base
  for _ = 1, 4096 do
    local p = ffi.cast(P, a)
    if p[0] == 0x4d and p[1] == 0x5a and u32(p + i32(p + 0x3c)) == 0x4550 then
      base = p
      break
    end
    a = a - 0x10000
  end
  if not base then return nil, "image base not found" end
  local pe = base + i32(base + 0x3c)
  local opt = pe + 24
  local img = { base = base, addr = ffi.cast("uint64_t", ffi.cast("uintptr_t", base)), sec = {} }
  -- timestamp, checksum, image size: what a cached result is tied to
  img.id = string.format("%x-%x-%x", u32(pe + 8), u32(opt + 64), u32(opt + 56))
  local s = opt + u16(pe + 20)
  for i = 0, u16(pe + 6) - 1 do
    local h = s + i * 40
    local n = {}
    for k = 0, 7 do
      if h[k] ~= 0 then n[#n + 1] = string.char(h[k]) end
    end
    local from, vsize, raw = u32(h + 12), u32(h + 8), u32(h + 16)
    img.sec[table.concat(n)] = { from = from, to = from + math.min(vsize, raw), vto = from + vsize }
  end
  if not (img.sec[".text"] and img.sec[".rdata"] and img.sec[".data"]) then
    return nil, "image sections missing"
  end
  return img
end

local function inSection(sec, rva, len)
  return rva >= sec.from and rva + (len or 8) <= sec.to
end

local function cStringAt(img, sec, rva, s)
  if not inSection(sec, rva, #s + 1) then return false end
  for k = 1, #s do
    if img.base[rva + k - 1] ~= string.byte(s, k) then return false end
  end
  return img.base[rva + #s] == 0
end

-- *** the log singleton: lea r8,"economy log"; lea rdx,"economylog"; call; mov rcx,[rip+log] ***

local function logGlobalAt(img, o)
  local b, rd = img.base, img.sec[".rdata"]
  if not inSection(img.sec[".text"], o, 26) then return nil end
  if not (match(b + o, { 0x4c, 0x8d, 0x05 }) and match(b + o + 7, { 0x48, 0x8d, 0x15 })
        and b[o + 14] == 0xe8 and match(b + o + 19, { 0x48, 0x8b, 0x0d })) then
    return nil
  end
  if not (cStringAt(img, rd, o + 7 + i32(b + o + 3), "economy log") and cStringAt(img, rd, o + 14 + i32(b + o + 10), "economylog")) then
    return nil
  end
  local g = o + 26 + i32(b + o + 22)
  local data = img.sec[".data"]
  if g < data.from or g + 8 > data.vto then return nil end
  return g
end

-- *** the trade list: four copies of one append function serve the cargo, offer, trade
-- and money lists in that order: mov ebx,<condensed>; mov r9d,<list>; cmove ebx,r9d ***

local appendSite = { 0xbb, false, false, 0, 0, 0x41, 0xb9, false, false, 0, 0, 0x41, 0x0f, 0x44, 0xd9,
  0x0f, 0x28, 0xf3, 0x48, 0x03, 0xd9, 0x45, 0x84, 0xc0, 0x74, 0x10, 0x48, 0x8b, 0x81 }

local function listOffsetAt(img, o)
  if not inSection(img.sec[".text"], o, #appendSite) or not match(img.base + o, appendSite) then return nil end
  return u32(img.base + o + 7)
end

-- One pass over the code for both sites; this Lua state has no JIT, so it costs
-- seconds and runs only when the build has no cached result.
local function scanCode(img)
  local b, tx = img.base, img.sec[".text"]
  local logSite, sites, appendsEnd = nil, {}, nil
  local stop = tx.to - 32
  local o = tx.from
  while o < stop do
    local c = b[o]
    if c == 0xbb then
      if b[o + 5] == 0x41 and b[o + 6] == 0xb9 and listOffsetAt(img, o) then
        sites[#sites + 1] = o
        if #sites > 4 then return nil, "more than four log list append sites" end
        -- the four sit within a few KB of each other; a fifth would be nearby too
        if #sites == 4 then appendsEnd = o + 0x10000 end
        if logSite and appendsEnd then stop = math.min(stop, appendsEnd) end
      end
    elseif c == 0x4c then
      if not logSite and b[o + 1] == 0x8d and b[o + 2] == 0x05 and b[o + 7] == 0x48 and logGlobalAt(img, o) then
        logSite = o
        if appendsEnd then stop = math.min(stop, math.max(appendsEnd, o + 1)) end
      end
    end
    o = o + 1
  end
  if not logSite then return nil, "economy log load site not found" end
  if #sites ~= 4 then return nil, "log list append sites not found" end
  for i = 2, 4 do
    if listOffsetAt(img, sites[i - 1]) >= listOffsetAt(img, sites[i]) then return nil, "log list append sites out of order" end
  end
  return logSite, sites[3]
end

-- *** RTTI: complete object locator in .rdata (signature 1, offset 0, self RVA) right
-- before the vtable, its TypeDescriptor name in .data ***

local classes = { object = ".?AVLogObject@U@@", ware = ".?AVWareClass@U@@" }

local function isVtableOf(img, vt, mangled)
  local b, rd = img.base, img.sec[".rdata"]
  if not inSection(rd, vt - 8, 16) then return false end
  local colPtr = u64(b + vt - 8)
  if colPtr < img.addr then return false end
  local col = tonumber(colPtr - img.addr)
  if not inSection(rd, col, 24) or u32(b + col) ~= 1 or u32(b + col + 4) ~= 0 or u32(b + col + 20) ~= col then
    return false
  end
  return cStringAt(img, img.sec[".data"], u32(b + col + 12) + 16, mangled)
end

-- RVA of the vtable an object points to, when it is the named class; nil otherwise.
local function vtableOf(img, p, mangled)
  if not plausible(p, 8) then return nil end
  local vt = u64(ffi.cast(P, p))
  if vt < img.addr then return nil end
  local rva = tonumber(vt - img.addr)
  return isVtableOf(img, rva, mangled) and rva or nil
end

local function fnv(s)
  local h = ffi.new("uint64_t", 0x811c9dc5)
  for i = 1, #s do
    local c = string.byte(s, i)
    if c >= 128 then c = c - 256 end
    ---@diagnostic disable-next-line: param-type-mismatch
    h = bit.bxor(h * FNV_PRIME, ffi.new("int64_t", c))
  end
  return h
end

-- MSVC std::string: inline buffer while capacity <= 15, else a pointer.
local function stdString(p)
  local size, cap = u64(p + 16), u64(p + 24)
  if size == 0 or size > 256 or cap < size then return nil end
  local data = p
  if cap > 15 then
    local heap = u64(p)
    if not plausible(heap, 8) then return nil end
    data = ffi.cast(P, heap)
  end
  return ffi.string(data, tonumber(size))
end

-- The inline form only: no pointer followed, so safe on an unproven layout.
local function inlineString(p)
  local size, cap = tonumber(u64(p + 16)), u64(p + 24)
  if cap ~= 15 or size == 0 or size > 15 or p[size] ~= 0 then return nil end
  return ffi.string(p, size)
end

local function isWareId(s)
  return s ~= nil and s:match("^[a-z0-9_]+$") ~= nil
end

-- The deque header, or nil when it does not look like one.
local function tradeDeque()
  local p = econlog.global[0]
  if not plausible(p, 8) then return nil end
  local d = ffi.cast(P, p) + layout.trades
  local map, mapSize, offset, size = u64(d + 8), u64(d + 16), u64(d + 24), u64(d + 32)
  if size == 0 then return { size = 0 } end
  ---@diagnostic disable-next-line: param-type-mismatch
  if not plausible(map, 8) or mapSize == 0 or bit.band(mapSize, mapSize - 1) ~= 0 or size > mapSize then
    return nil
  end
  return { map = ffi.cast(P, map), mapSize = mapSize, offset = offset, size = tonumber(size) }
end

local function entryAt(dq, k)
  local p = u64(dq.map + ((dq.offset + k) % dq.mapSize) * 8)
  if not plausible(p, 8) then return nil end
  return ffi.cast(P, p)
end

-- Ware id by WareClass pointer, proven by the vtable and its own hash once each.
local wareIds = {}
local function wareIdOf(p)
  if not plausible(p, 8) then return nil end
  local key = tonumber(p)
  local id = wareIds[key]
  if id == nil then
    local w = ffi.cast(P, p)
    id = false
    if u64(w) == econlog.wareVt then
      local s = stdString(w + layout.wareId)
      if layout.wareHash == 0 then
        if isWareId(s) then id = s end
      elseif s and fnv(s) == u64(w + layout.wareHash) then
        id = s
      end
    end
    wareIds[key] = id
  end
  return id or nil
end

-- 0 for no object, nil for a pointer that is not a LogObject.
local function componentOf(entry, offset)
  local p = u64(entry + offset)
  if p == 0 then return 0 end
  if not plausible(p, 8) then return nil end
  local o = ffi.cast(P, p)
  if u64(o) ~= econlog.objectVt then return nil end
  return tonumber(u64(o + layout.objectId))
end

local function readEntry(dq, k)
  local e = entryAt(dq, k)
  local wareId = e and wareIdOf(u64(e + layout.entryWare))
  local buyer = wareId and componentOf(e, layout.entryBuyer)
  local seller = buyer and componentOf(e, layout.entrySeller)
  if not seller then return nil end
  return ffi.cast("double*", e + layout.entryTime)[0], wareId, buyer, seller,
      tonumber(ffi.cast("int64_t*", e + layout.entryPrice)[0]), i32(e + layout.entryAmount)
end

local function knownWareLayout(c)
  for _, l in ipairs(wareLayouts) do
    if c.wareId == l.id and c.wareHash == l.hash then return l end
  end
end

local function use(img, c)
  econlog.global = ffi.cast("uint64_t*", img.base + logGlobalAt(img, c.logSite))
  layout.trades = listOffsetAt(img, c.appendSite)
  layout.wareId, layout.wareHash = c.wareId, c.wareHash
  econlog.objectVt = img.addr + c.objectVt
  econlog.wareVt = img.addr + c.wareVt
end

-- Cached RVAs still describing this exe: a few bounded reads.
local function verifyCached(img, c)
  if not (knownWareLayout(c) and logGlobalAt(img, c.logSite) and listOffsetAt(img, c.appendSite)
        and isVtableOf(img, c.objectVt, classes.object) and isVtableOf(img, c.wareVt, classes.ware)) then
    return false
  end
  use(img, c)
  return true
end

-- Which wareLayouts entry this build uses, judged from inline ids only (no pointer is
-- followed before the layout is known): a hash match proves the first, three distinct
-- clean ids at +0x08 the second. nil while too few wares have short ids.
local function wareLayoutOf(dq, wareVt)
  local seen, plain = {}, 0
  for k = dq.size - 1, math.max(0, dq.size - 4096), -1 do
    local e = entryAt(dq, k)
    local p = e and u64(e + layout.entryWare)
    if p and plausible(p, 8) and not seen[tonumber(p)] then
      seen[tonumber(p)] = true
      local w = ffi.cast(P, p)
      if u64(w) == wareVt then
        local hashed = wareLayouts[1]
        local s = inlineString(w + hashed.id)
        if s and fnv(s) == u64(w + hashed.hash) then return hashed end
        if isWareId(inlineString(w + wareLayouts[2].id)) then
          plain = plain + 1
          if plain >= 3 then return wareLayouts[2] end
        end
      end
    end
  end
end

-- The full search. Returns the cache record, or nil with a reason when the answer is
-- not final yet (too few trades logged so far to learn the classes from).
local function search(img, build)
  local logSite, appendSite3 = scanCode(img)
  if not logSite then return { build = build, found = false, reason = appendSite3 } end
  econlog.global = ffi.cast("uint64_t*", img.base + logGlobalAt(img, logSite))
  layout.trades = listOffsetAt(img, appendSite3)
  local dq = tradeDeque()
  if not dq then return { build = build, found = false, reason = "trade list header implausible" } end
  if dq.size == 0 then return nil, "no trade logged yet" end
  local e = entryAt(dq, dq.size - 1)
  if not e then return { build = build, found = false, reason = "newest trade unreadable" } end
  local wareVt = vtableOf(img, u64(e + layout.entryWare), classes.ware)
  local objectVt = vtableOf(img, u64(e + layout.entryBuyer), classes.object)
      or vtableOf(img, u64(e + layout.entrySeller), classes.object)
  if not (wareVt and objectVt) then return { build = build, found = false, reason = "trade entry layout changed" } end
  local ware = wareLayoutOf(dq, img.addr + wareVt)
  if not ware then return nil, "no ware id readable yet" end
  return {
    build = build, found = true, logSite = logSite, appendSite = appendSite3,
    objectVt = objectVt, wareVt = wareVt, wareId = ware.id, wareHash = ware.hash,
  }
end

local function failed(build, reason)
  return { build = build, found = false, reason = reason }
end

-- Flushed before engine memory is read and replaced after: a crash on the way leaves
-- it behind, so every later load of this build treats the log as not available.
local function interrupted(build)
  return failed(build, "the game stopped while the engine log was read")
end

local function store(record)
  -- savedvariable (ui.xml, userdata storage): one search per game build
  if record then record.v = RECORD_VERSION end
  ---@diagnostic disable-next-line: global-in-non-module
  __STA_ENGINE_LOG = record
  local saved, err = pcall(function() ffi.C.SaveUIUserData() end)
  if not saved then DebugError("[STA] engine log: SaveUIUserData failed: " .. tostring(err)) end
end

-- At Lua init. A build with a cached answer costs a few reads; a new build is searched
-- only while the option is on. state: "found" | "missing" | "unknown" (not searched yet).
function econlog.detect(enabled)
  econlog.detected = false
  econlog.state = "unknown"
  econlog.record = nil
  wareIds = {}
  local build
  local ok, err = pcall(function()
    local img, why = mapImage()
    if not img then
      econlog.state = "missing"
      return why
    end
    build = GetVersionString() .. " " .. img.id
    local c = __STA_ENGINE_LOG
    if type(c) ~= "table" or c.build ~= build or c.v ~= RECORD_VERSION then c = nil end
    if c and not c.found then
      econlog.state = "missing"
      return "cached: " .. tostring(c.reason)
    end
    -- off: the cached answer is enough, nothing is read
    if not enabled then
      econlog.state = c and "found" or "unknown"
      return c and "found earlier, option off" or ("not searched for " .. build)
    end

    store(interrupted(build))
    local record
    if c and verifyCached(img, c) then
      record = c
    else
      local pending
      record, pending = search(img, build)
      if not record then
        store(nil)
        return pending
      end
      if record.found then use(img, record) end
    end
    if record.found then
      local dq = tradeDeque()
      if not dq then
        record = failed(build, "trade list header implausible")
      else
        -- with entries present, the first and last must read cleanly too
        for _, k in ipairs(dq.size > 0 and { 0, dq.size - 1 } or {}) do
          if record.found and not readEntry(dq, k) then record = failed(build, "trade " .. k .. " unreadable") end
        end
      end
    end
    store(record)
    if not record.found then
      econlog.state = "missing"
      return "searched: " .. tostring(record.reason)
    end
    econlog.record = record
    econlog.state = "found"
    econlog.detected = true
    return string.format("%s: trades at +%s", build, hex(layout.trades))
  end)
  econlog.reason = ok and tostring(err) or ("error: " .. tostring(err))
  if not ok then
    econlog.state = "missing"
    if build then store(failed(build, econlog.reason)) end
  end
  return econlog.detected
end

-- Calls onTrade(time, wareId, buyerId, sellerId, priceCents, amount) oldest first;
-- ids are numbers, 0 when the side is empty. Returns the count read and skipped.
function econlog.readTrades(onTrade)
  if not econlog.detected then return 0, 0 end
  local dq = tradeDeque()
  if not dq then return 0, 0 end
  store(interrupted(econlog.record.build))
  local read, skipped = 0, 0
  for k = 0, dq.size - 1 do
    local t, wareId, buyer, seller, price, amount = readEntry(dq, k)
    if t then
      onTrade(t, wareId, buyer, seller, price, amount)
      read = read + 1
    else
      skipped = skipped + 1
      -- a layout that stopped matching: stop before following more of it
      if read == 0 and skipped >= 16 then
        econlog.detected = false
        econlog.state = "missing"
        econlog.reason = "trade entries stopped matching the layout"
        break
      end
    end
  end
  store(econlog.detected and econlog.record or failed(econlog.record.build, econlog.reason))
  return read, skipped
end

Register_Require_Response("extensions.ships_trade_analyzer.ui.sta_econlog", econlog)

return econlog
