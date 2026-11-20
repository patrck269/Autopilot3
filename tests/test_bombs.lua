-- Bomb selection, interlocks and the bay wrapper. Run from the repo root:
--   lua tests/test_bombs.lua
package.path = "./?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local bombs = require("ap3.bombs")
local bombbay = require("ap3.bombbay")
local CFG = dofile("ap3/config.lua")
local cfg = CFG.bombs

local expected_layout = {
  [14]={0,1}, [34]={0,21}, [13]={0,22}, [35]={0,23},
  [36]={1,23}, [58]={1,1},
}
local seen = {}
for id = 13, 58 do
  local cell = bombs.LAYOUT[id]
  A.eq(cell ~= nil, true, "layout id " .. id)
  local key = cell[1] .. ":" .. cell[2]
  A.eq(seen[key], nil, "unique layout " .. key)
  seen[key] = id
end
for id, cell in pairs(expected_layout) do
  A.eq(bombs.LAYOUT[id][1], cell[1], "layout col " .. id)
  A.eq(bombs.LAYOUT[id][2], cell[2], "layout row " .. id)
end

local all = {}
for id = 13, 58 do all[#all + 1] = id end
local function ids_text(ids) return table.concat(ids, ",") end
local selections = {
  [1]="25", [3]="14,35,47", [5]="19,25,31,36,58",
  [10]="16,19,23,26,31,34,36,43,51,58",
}
for size, expected in pairs(selections) do
  A.eq(ids_text(bombs.select(all, size)), expected, "full selection " .. size)
end
local remaining = { table.unpack(all) }
local singles = {}
for _ = 1, 6 do
  local pick = bombs.select(remaining, 1)[1]
  singles[#singles + 1] = pick
  for index, id in ipairs(remaining) do
    if id == pick then table.remove(remaining, index) break end
  end
end
A.eq(ids_text(singles), "25,47,24,46,26,48", "successive singles")
local none, reason = bombs.select({13,14}, 3)
A.eq(none, nil, "insufficient selection")
A.eq(reason, "only 2 left", "insufficient reason")

local function relay(id, log)
  return {
    setOutput = function(side, value)
      log[#log + 1] = { id=id, side=side, value=value }
    end,
  }
end
local log, relays = {}, {}
for id = 13, 59 do relays[id] = relay(id, log) end
local b = bombs.new()
A.eq(bombs.check(b, 0, 250, true, cfg), "doors closed", "closed check")
bombs.open_doors(b, 0, relays[59], cfg)
for _, event in ipairs(log) do A.eq(event.value, false, "door open removes signal") end
A.eq(bombs.check(b, 0.999, 250, true, cfg) ~= nil, true, "drop blocked before one second")
A.eq(bombs.check(b, 1, 250, true, cfg), nil, "drop unlocked at one second")
A.eq(bombs.check(b, 3, 199.5, true, cfg), "below 200 (Y 199)", "altitude check")
A.eq(bombs.check(b, 3, 200, true, cfg), nil, "minimum altitude")

log = {}
for id = 13, 59 do relays[id] = relay(id, log) end
b = bombs.new()
b.doors_open, b.opened_at, b.last_drop_at = true, -3, 0
A.eq(bombs.check(b, 4, 250, true, cfg), "wait 1s", "interval check")
A.eq(bombs.check(b, 5, 250, true, cfg), nil, "interval elapsed")
b.last_drop_at = nil
local dropped = bombs.drop(b, 5, 250, relays, cfg)
A.eq(ids_text(dropped), "25", "drop selection")
A.eq(#log, 6, "six trigger sides")
for _, event in ipairs(log) do A.eq(event.value, true, "trigger on") end
bombs.update(b, 5.5, relays, relays[59], cfg)
A.eq(b.pulse, nil, "pulse completed")
A.eq(b.close_at, 15.5, "close scheduled")
A.eq(#log, 12, "six trigger sides off")
for index = 7, 12 do A.eq(log[index].value, false, "trigger off") end
bombs.update(b, 15.5, relays, relays[59], cfg)
A.eq(b.doors_open, false, "doors auto-close")
for index = 13, 18 do A.eq(log[index].value, true, "auto-close applies signal") end

b = bombs.new()
b.doors_open, b.opened_at = true, -3
bombs.drop(b, 0, 250, relays, cfg)
bombs.update(b, 0.5, relays, relays[59], cfg)
bombs.drop(b, 6, 250, relays, cfg)
bombs.update(b, 6.5, relays, relays[59], cfg)
A.eq(b.close_at, 16.5, "second drop moves close")

-- ap3.bombbay with a fake peripheral API and store. calls logs every relay
-- output and every save, in order.
local function bay_world(opts)
  opts = opts or {}
  local calls, files = {}, { [CFG.bomb_file] = opts.file }
  local relays = {}
  for id = 13, 59 do
    if not (opts.missing and opts.missing[id]) then
      relays[cfg.relay_prefix .. id] = {
        setOutput = function(side, value) calls[#calls + 1] = { kind = "out", id = id, side = side, value = value } end,
      }
    end
  end
  local P = {
    isPresent = function(name) return relays[name] ~= nil end,
    hasType = function(name, t) return relays[name] ~= nil and t == "redstone_relay" end,
    getType = function(name) return relays[name] and "redstone_relay" or nil end,
    wrap = function(name) return relays[name] end,
  }
  local store = {
    load = function(path) return files[path] end,
    save = function(path, value)
      calls[#calls + 1] = { kind = "save", value = value }
      files[path] = value
      return true
    end,
  }
  local bay = bombbay.new(CFG, P, store)
  bay:scan()
  return bay, calls, files
end

do
  local bay, calls = bay_world()
  bay:safe()
  for _, event in ipairs(calls) do
    A.eq(event.value, event.id == 59, "startup closes doors without firing bombs")
  end
  local before = #calls
  bay:command("doors", "open", { y = 250 }, 0)
  for i = before + 1, #calls do A.eq(calls[i].value, false, "manual open removes signal") end
  before = #calls
  bay:command("doors", "close", { y = 250 }, 4)
  for i = before + 1, #calls do A.eq(calls[i].value, true, "manual close applies signal") end
end

do
  local bay, calls, files = bay_world()
  A.eq(bay:command("doors", "open", { y = 250 }, 0), true, "bay doors open")
  local before = #calls
  local ok, text = bay:command("drop", nil, { y = 250 }, 1)
  A.eq(ok, true, "bay drop")
  A.eq(text, "dropped 25", "bay drop text")
  local saved_at, fired_at
  for i = before + 1, #calls do
    local c = calls[i]
    if c.kind == "save" and not saved_at then saved_at = i end
    if c.kind == "out" and c.value == true and c.id ~= 59 and not fired_at then fired_at = i end
  end
  A.eq(saved_at ~= nil and fired_at ~= nil and saved_at < fired_at, true, "salvo saved before any trigger fires")
  A.eq(files[CFG.bomb_file].used[1], 25, "saved used list")
  local st = bay:status(3, 250)
  A.eq(st.left, 45, "one bomb gone")
  A.eq(st.used[25], true, "used map")
end

do
  local bay = bay_world({ file = { used = { 99 }, size = 3 } })
  A.eq(bay:status(0, 250).left, 46, "file with id 99 ignored")
  A.eq(bay:status(0, 250).size, 1, "its salvo size ignored too")
  local good = bay_world({ file = { used = { 14, 58 }, size = 5 } })
  A.eq(good:status(0, 250).left, 44, "valid file loaded")
  A.eq(good:status(0, 250).size, 5, "valid salvo size loaded")
end

do
  local bay = bay_world({ missing = { [59] = true } })
  local ok, text = bay:command("doors", "open", { y = 250 }, 0)
  A.eq(ok, false, "doors refused without relay 59")
  A.eq(text, "doors relay missing", "doors refusal text")
  A.eq(bay:status(0, 250).reason, "doors relay missing", "drop reason without relay 59")
end

do
  local bay = bay_world()
  local ok, text = bay:command("salvo", 4, nil, 0)
  A.eq(ok, false, "salvo 4 rejected")
  A.eq(text, "salvo must be 1, 3, 5, 10 or all", "salvo rejection text")
  A.eq(bay:command("salvo", "all", nil, 0), true, "salvo all accepted")
  A.eq(bay:status(0, 250).size, "all", "salvo all set")
end

print("ALL BOMB CHECKS PASSED")
