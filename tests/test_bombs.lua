package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local config = require("config")
local bombs = require("bombs")
local cfg = config.default()

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
bombs.open_doors(b, 0, relays[59])
A.eq(bombs.check(b, 1, 250, true, cfg), "doors opening 2s", "settle check")
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

b = bombs.new()
b.doors_open, b.opened_at = true, -3
bombs.drop(b, 0, 250, relays, cfg)
bombs.update(b, 0.5, relays, relays[59], cfg)
bombs.drop(b, 6, 250, relays, cfg)
bombs.update(b, 6.5, relays, relays[59], cfg)
A.eq(b.close_at, 16.5, "second drop moves close")
