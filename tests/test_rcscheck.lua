-- Layout inference from slide and bearing evidence, including missing slide.
package.path = "./?.lua;" .. package.path
local check = require("ap3.rcscheck")
local cfg = dofile("ap3/config.lua")
local corners = check.CORNERS
local response = {
  bow_port = { dside = -0.5, dfwd = 0, dh = -0.4 },
  bow_stbd = { dside = 0.5, dfwd = 0, dh = 0.4 },
  stern_port = { dside = -0.5, dfwd = 0, dh = 0.4 },
  stern_stbd = { dside = 0.5, dfwd = 0, dh = -0.4 },
}
local function results(order, missing)
  local c = check.new(cfg)
  for i, id in ipairs(corners) do
    local r = response[order[i]]
    c.results[id] = { dside = missing and missing[id] and 0 or r.dside, dfwd = r.dfwd, dh = r.dh }
  end
  return c
end
local order, used, combinations = {}, {}, 0
local function permutations(i)
  if i > #corners then
    -- Every permutation must still be recoverable with one missing slide.
    for _, missing in ipairs(corners) do
      local c = results(order, { [missing] = true })
      local layout, why = c:layout()
      assert(layout, why)
      for j, physical in ipairs(order) do assert(layout[physical] == corners[j], "wrong inferred corner") end
      combinations = combinations + 1
    end
    return
  end
  for _, corner in ipairs(corners) do
    if not used[corner] then
      used[corner], order[i] = true, corner
      permutations(i + 1)
      used[corner] = nil
    end
  end
end
permutations(1)
print("Recovered " .. combinations .. " mixed slide/bearing layouts")

-- The screenshot's yaw-only readings are evidence, but do not uniquely tell
-- swapped mounting from reversed thrust. Never save one arbitrary solution.
do
  local c = check.new(cfg)
  for _, id in ipairs(corners) do
    c.results[id] = { dside = 0, dfwd = 0, dh = id:find("bow", 1, true) and 0.4 or -0.4 }
  end
  assert(c:layout() == nil, "ambiguous yaw-only response yielded a guessed layout")
end

do
  local c = results(corners)
  c.results.bow_port = { dside = 0, dfwd = 0, dh = 0 }
  assert(c:layout() == nil, "a silent motor was assigned a corner")
  c = results(corners)
  c.results.bow_port = { dside = 0, dfwd = 0.5, dh = 0.4 }
  assert(c:layout() == nil, "fore/aft thrust was assigned a sideways puller layout")
end

-- Common yaw drift does not invalidate the relative turn comparison when
-- slide identifies both sides, including crossing the heading wrap boundary.
do
  local c = results(corners)
  for _, r in pairs(c.results) do r.dh = r.dh + 1 end
  local layout = assert(c:layout())
  for _, id in ipairs(corners) do assert(layout[id] == id) end
  c = check.new(cfg)
  local s = { hdg = 359.8, v_side = 0, v_fwd = 0 }
  c:step(s, 0, function() end)
  c:step(s, cfg.rcs_check.settle, function() end)
  c:step(s, cfg.rcs_check.settle + cfg.rcs_check.on, function() end)
  s.hdg = 0.2
  c:step(s, cfg.rcs_check.settle + cfg.rcs_check.on + cfg.rcs_check.coast, function() end)
  assert(math.abs(c.results.bow_port.dh - 0.4) < 1e-6, "bearing wrap changed turn direction")
end
print("ALL RCS CHECKS PASSED")
