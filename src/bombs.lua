local M = {}
local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local DEFAULTS = {
  bomb_min_altitude = 200,
  bomb_min_interval = 5,
  door_settle = 3,
  door_close_delay = 10,
  bomb_pulse = 0.5,
}

M.LAYOUT = {}
for row = 1, 21 do
  M.LAYOUT[13 + row] = { 0, row }
end
M.LAYOUT[13] = { 0, 22 }
M.LAYOUT[35] = { 0, 23 }
for row = 1, 23 do
  M.LAYOUT[59 - row] = { 1, row }
end

do
  local count = 0
  for id = 13, 58 do
    assert(M.LAYOUT[id] ~= nil, "bomb layout missing id " .. id)
    count = count + 1
  end
  for id in pairs(M.LAYOUT) do
    assert(id >= 13 and id <= 58, "bomb layout has invalid id " .. tostring(id))
  end
  assert(count == 46, "bomb layout must contain 46 ids")
end

local function setting(cfg, name)
  if cfg ~= nil and cfg[name] ~= nil then
    return cfg[name]
  end
  return DEFAULTS[name]
end

local function relay_ok(relay)
  return type(relay) == "table" and type(relay.setOutput) == "function"
end

local function set_all(relay, value)
  if not relay_ok(relay) then return end
  for _, side in ipairs(SIDES) do
    relay.setOutput(side, value)
  end
end

function M.new()
  return {
    used = {},
    size = 1,
    doors_open = false,
    opened_at = nil,
    last_drop_at = nil,
    pulse = nil,
    close_at = nil,
  }
end

function M.available(b, relays)
  local ids = {}
  for id = 13, 58 do
    if not b.used[id] and relay_ok(relays[id]) then
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function distance_squared(a, b)
  local ac, ar = M.LAYOUT[a][1], M.LAYOUT[a][2]
  local bc, br = M.LAYOUT[b][1], M.LAYOUT[b][2]
  local dc, dr = ac - bc, ar - br
  return dc * dc + dr * dr
end

local function sorted_copy(values)
  local copy = {}
  for i, value in ipairs(values) do copy[i] = value end
  table.sort(copy)
  return copy
end

local function score(ids, picks)
  local min_pair = math.huge
  if #picks > 1 then
    for i = 1, #picks - 1 do
      for j = i + 1, #picks do
        min_pair = math.min(min_pair, distance_squared(picks[i], picks[j]))
      end
    end
  end

  local picked = {}
  for _, id in ipairs(picks) do picked[id] = true end
  local col_sum, row_sum, remaining = 0, 0, 0
  for _, id in ipairs(ids) do
    if not picked[id] then
      col_sum = col_sum + M.LAYOUT[id][1]
      row_sum = row_sum + M.LAYOUT[id][2]
      remaining = remaining + 1
    end
  end
  local balance = 0
  if remaining > 0 then
    local dc = col_sum / remaining - 0.5
    local dr = row_sum / remaining - 12
    balance = math.sqrt(dc * dc + dr * dr)
  end
  return { -min_pair, balance, sorted_copy(picks) }
end

local function score_less(a, b)
  if b == nil then return true end
  if a[1] ~= b[1] then return a[1] < b[1] end
  if a[2] ~= b[2] then return a[2] < b[2] end
  for i = 1, #a[3] do
    if a[3][i] ~= b[3][i] then
      return a[3][i] < b[3][i]
    end
  end
  return false
end

function M.select(ids, size)
  ids = sorted_copy(ids)
  if #ids == 0 then
    return nil, "no bombs left"
  end
  if size == "all" then
    return ids
  end
  if #ids < size then
    return nil, "only " .. #ids .. " left"
  end

  local best, best_score
  for _, seed in ipairs(ids) do
    local picks = { seed }
    local chosen = { [seed] = true }
    while #picks < size do
      local farthest, farthest_distance
      for _, candidate in ipairs(ids) do
        if not chosen[candidate] then
          local nearest = math.huge
          for _, pick in ipairs(picks) do
            nearest = math.min(nearest, distance_squared(candidate, pick))
          end
          if farthest == nil or nearest > farthest_distance
              or (nearest == farthest_distance and candidate < farthest) then
            farthest = candidate
            farthest_distance = nearest
          end
        end
      end
      picks[#picks + 1] = farthest
      chosen[farthest] = true
    end
    local candidate_score = score(ids, picks)
    if score_less(candidate_score, best_score) then
      best = candidate_score[3]
      best_score = candidate_score
    end
  end
  return best
end

function M.check(b, now, altitude, door_present, cfg)
  if b.pulse ~= nil then
    return "drop in progress"
  end
  if not door_present then
    return "doors relay missing"
  end
  if not b.doors_open then
    return "doors closed"
  end
  local remaining = setting(cfg, "door_settle") - (now - b.opened_at)
  if remaining > 0 then
    return "doors opening " .. math.ceil(remaining) .. "s"
  end
  if type(altitude) ~= "number" then
    return "no altitude"
  end
  local minimum = setting(cfg, "bomb_min_altitude")
  if altitude < minimum then
    return "below " .. minimum .. " (Y " .. math.floor(altitude) .. ")"
  end
  if b.last_drop_at ~= nil then
    remaining = setting(cfg, "bomb_min_interval") - (now - b.last_drop_at)
    if remaining > 0 then
      return "wait " .. math.ceil(remaining) .. "s"
    end
  end
  return nil
end

function M.drop(b, now, altitude, relays, cfg, before_fire)
  local reason = M.check(b, now, altitude, relay_ok(relays[cfg.door_relay]), cfg)
  if reason ~= nil then return nil, reason end
  local ids, select_reason = M.select(M.available(b, relays), b.size)
  if ids == nil then return nil, select_reason end
  for _, id in ipairs(ids) do b.used[id] = true end
  b.pulse = { ids = ids, ends_at = now + cfg.bomb_pulse }
  b.last_drop_at = now
  b.close_at = nil
  if before_fire ~= nil then before_fire(ids) end
  for _, id in ipairs(ids) do set_all(relays[id], true) end
  return ids
end

function M.open_doors(b, now, door)
  set_all(door, true)
  if not b.doors_open then b.opened_at = now end
  b.doors_open = true
end

function M.close_doors(b, door)
  if b.pulse ~= nil then return nil, "drop in progress" end
  set_all(door, false)
  b.doors_open = false
  b.opened_at = nil
  b.close_at = nil
  return true
end

function M.update(b, now, relays, door, cfg)
  if b.pulse ~= nil and now >= b.pulse.ends_at then
    for _, id in ipairs(b.pulse.ids) do set_all(relays[id], false) end
    b.pulse = nil
    b.close_at = now + cfg.door_close_delay
  end
  if b.close_at ~= nil and b.pulse == nil and now >= b.close_at then
    M.close_doors(b, door)
  end
end

function M.deadline(b)
  local deadline = b.pulse ~= nil and b.pulse.ends_at or nil
  if b.close_at ~= nil and (deadline == nil or b.close_at < deadline) then
    deadline = b.close_at
  end
  return deadline
end

function M.reload(b)
  if b.pulse ~= nil then return nil, "drop in progress" end
  b.used = {}
  return true
end

return M
