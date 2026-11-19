-- Bomb bay on the flight computer: wraps the redstone relays, keeps the
-- record of used bombs and the salvo size on disk, and turns bay commands
-- into ap3/bombs.lua calls. Trigger relays are 13..58 (one bomb each), the
-- door relay is 59.
local bombs = require("ap3.bombs")

local M = {}
M.__index = M

local FIRST, LAST = 13, 58

local function size_ok(sizes, v)
  for _, s in ipairs(sizes) do
    if s == v then return true end
  end
  return false
end

local function sorted_used(b)
  local ids = {}
  for id = FIRST, LAST do
    if b.used[id] then ids[#ids + 1] = id end
  end
  return ids
end

-- cfg: full config. P: peripheral API. store: ap3/store.lua.
function M.new(cfg, P, store)
  local self = setmetatable({
    cfg = cfg.bombs,
    file = cfg.bomb_file,
    P = P,
    store = store,
    b = bombs.new(),
    relays = {},
    preview = nil,
    preview_key = nil,
  }, M)
  local saved = store.load(self.file)
  if type(saved) == "table" and type(saved.used) == "table" and size_ok(self.cfg.sizes, saved.size) then
    local ok = true
    for _, id in ipairs(saved.used) do
      if type(id) ~= "number" or id ~= math.floor(id) or id < FIRST or id > LAST then ok = false end
    end
    if ok then
      for _, id in ipairs(saved.used) do self.b.used[id] = true end
      self.b.size = saved.size
    end
  end
  return self
end

-- Wrap every present relay; a missing one (or another block type) is nil.
function M:scan()
  local P = self.P
  for id = FIRST, self.cfg.door_relay do
    local name = self.cfg.relay_prefix .. id
    local present = P.isPresent(name)
    if present and P.hasType then
      local ok, yes = pcall(P.hasType, name, "redstone_relay")
      present = ok and yes == true
    elseif present then
      present = P.getType(name) == "redstone_relay"
    end
    self.relays[id] = present and P.wrap(name) or nil
  end
  self.preview_key = nil
end

-- Every output of every relay off: no trigger or door left on by a restart.
function M:safe()
  for id = FIRST, self.cfg.door_relay do
    local r = self.relays[id]
    if r then
      for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
        pcall(r.setOutput, side, false)
      end
    end
  end
end

function M:save()
  self.store.save(self.file, { used = sorted_used(self.b), size = self.b.size })
end

-- Handle a bay command. s: latest telemetry. Returns ok, text.
function M:command(c, v, s, now)
  local b, cfg = self.b, self.cfg
  local door = self.relays[cfg.door_relay]
  if c == "doors" then
    if v == "open" then
      if not door then return false, "doors relay missing" end
      bombs.open_doors(b, now, door)
      return true, "doors open"
    elseif v == "close" then
      local ok, reason = bombs.close_doors(b, door)
      if not ok then return false, reason end
      return true, "doors closed"
    end
    return false, "doors open | doors close"
  elseif c == "drop" then
    local ids, reason = bombs.drop(b, now, s and s.y, self.relays, cfg, function() self:save() end)
    self.preview_key = nil
    if not ids then return false, reason end
    return true, "dropped " .. table.concat(ids, ",")
  elseif c == "salvo" then
    if not size_ok(cfg.sizes, v) then return false, "salvo must be 1, 3, 5, 10 or all" end
    b.size = v
    self:save()
    return true, "salvo " .. tostring(v)
  elseif c == "reload" then
    local ok, reason = bombs.reload(b)
    if not ok then return false, reason end
    self.preview_key = nil
    self:save()
    return true, "bombs reloaded"
  end
  return false, "unknown bay command " .. tostring(c)
end

-- Ends trigger pulses and closes the doors when due. Call every loop.
function M:update(now)
  bombs.update(self.b, now, self.relays, self.relays[self.cfg.door_relay], self.cfg)
end

-- Bay state for the displays. y: current altitude.
function M:status(now, y)
  local b, cfg = self.b, self.cfg
  local available = bombs.available(b, self.relays)
  local used = sorted_used(b)
  -- A 10-bomb selection is too slow to run every status: cache it until the
  -- salvo size, the used bombs or the relays change.
  local key = tostring(b.size) .. ":" .. table.concat(used, ",")
  if key ~= self.preview_key then
    self.preview_key = key
    local ids, why = bombs.select(available, b.size)
    self.preview, self.preview_why = ids or {}, (not ids) and why or nil
  end
  local door_present = self.relays[cfg.door_relay] ~= nil
  local reason = bombs.check(b, now, y, door_present, cfg) or self.preview_why
  local used_map, present = {}, {}
  for _, id in ipairs(used) do used_map[id] = true end
  for id = FIRST, LAST do present[id] = self.relays[id] ~= nil end
  return {
    left = #available,
    size = b.size,
    doors_open = b.doors_open,
    door_open_for = b.doors_open and b.opened_at and (now - b.opened_at) or nil,
    reason = reason,
    preview = self.preview,
    used = used_map,
    present = present,
    door_present = door_present,
    sizes = cfg.sizes,
  }
end

return M
