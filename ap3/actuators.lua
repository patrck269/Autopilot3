-- Electric motor bank: the ten Create Crafts & Additions electric motors that
-- drive the props, one RPM per motor.
--
-- The flight loop only records desired RPM; the writer coroutine calls
-- service(), which writes at most one motor per call (setSpeed runs on the
-- server thread and stalls for a tick) under these rules:
--   * RPM clamped to the motor cap and rounded to an integer
--   * each motor is written at most every min_interval[group] seconds, and
--     changes smaller than deadband[group] are skipped
--   * each group (four lift corners, four RCS corners, two pushers) is
--     written as one batch: the motors turning down go first, then the ones
--     turning up, each on consecutive ticks, so the hull never runs on a
--     stray corner or a lone pusher
--   * the lift goes first, then the largest weighted need
--   * kill() bypasses pacing so zero goes out immediately
local util = require("ap3.util")

local M = {}
M.__index = M

M.ORDER = {
  "lift_bow_port", "lift_bow_stbd", "lift_stern_port", "lift_stern_stbd",
  "bow_port", "bow_stbd", "stern_port", "stern_stbd",
  "thrust_port", "thrust_stbd",
}
M.GROUPS = {
  lift = { "lift_bow_port", "lift_bow_stbd", "lift_stern_port", "lift_stern_stbd" },
  rcs = { "bow_port", "bow_stbd", "stern_port", "stern_stbd" },
  thrust = { "thrust_port", "thrust_stbd" },
}
local RCS = M.GROUPS.rcs

local GROUP = {}
for name, ids in pairs(M.GROUPS) do
  for _, id in ipairs(ids) do GROUP[id] = name end
end

local CORNER_NAME = {
  bow_port = "BOW PORT", bow_stbd = "BOW STBD", stern_port = "STRN PORT", stern_stbd = "STRN STBD",
}
M.CORNER_NAME = CORNER_NAME

-- Use the RCS layout found by an RCS check: map[corner] = peripheral name of
-- the motor whose props really sit at that corner. Changes cfg in place
-- (call before wrapping devices). Returns true if anything moved.
function M.apply_layout(cfg, map)
  if type(map) ~= "table" then return false end
  local known = {}
  for _, id in ipairs(RCS) do known[cfg.motors[id].name] = true end
  for _, id in ipairs(RCS) do
    if type(map[id]) ~= "string" or not known[map[id]] then return false end
  end
  local moved = false
  for _, id in ipairs(RCS) do
    local c = cfg.motors[id]
    if c.name ~= map[id] then moved = true end
    c.name = map[id]
    c.label = "R" .. (map[id]:match("(%d+)$") or "?") .. " " .. CORNER_NAME[id]
  end
  return moved
end

-- devices: map channel -> wrapped motor (nil when missing)
function M.new(cfg, devices, clock)
  local self = setmetatable({
    cfg = cfg.actuator,
    clock = clock or os.clock,
    ch = {},
    urgent = false,
    batch = {}, -- motors still to write in the running group batch
  }, M)
  for _, id in ipairs(M.ORDER) do
    local c = cfg.motors[id]
    self.ch[id] = {
      id = id,
      name = c.name,
      label = c.label,
      cap = c.cap,
      sign = c.sign or 1,
      group = GROUP[id],
      dev = devices[id],
      applied = nil,  -- last RPM known to be on the motor
      desired = nil,  -- nil = leave the motor alone
      last_write = -math.huge,
      writes = 0,
      fault = nil,
      prop = nil,     -- modelled spin of the props behind it (RPM)
    }
  end
  return self
end

-- Read the current speeds so the first writes slew from where the ship is.
function M:seed()
  for _, id in ipairs(M.ORDER) do
    local c = self.ch[id]
    if c.dev and c.dev.getSpeed then
      local ok, v = pcall(c.dev.getSpeed)
      if ok and util.finite(v) then
        c.applied = util.round(v * c.sign)
        c.prop = c.applied -- assume a running ship's props are already at speed
      end
    end
  end
end

function M:set_device(id, dev)
  local c = self.ch[id]
  c.dev = dev
  if dev == nil then c.applied = nil end
end

function M:set(id, rpm)
  local c = self.ch[id]
  if rpm == nil then
    c.desired = nil
    return
  end
  if not util.finite(rpm) then rpm = 0 end
  c.desired = util.clamp(util.round(rpm), -c.cap, c.cap)
end

-- Emergency: every motor to zero, ignoring pacing.
function M:kill()
  for _, id in ipairs(M.ORDER) do self.ch[id].desired = 0 end
  self.urgent = true
  self.batch = {}
end

function M:applied(id)
  return self.ch[id].applied or 0
end

-- Advance the modelled prop spin to time now. Clockwork's propeller bearing
-- (PropellerBearingBlockEntity.tick) moves its spin half way to the target
-- each tick, at most 32 RPM per tick: 2000 RPM takes about 3.1 s.
function M:spin(now)
  local t = self.spin_t or now
  local steps = math.min(200, math.floor((now - t) / 0.05 + 1e-6))
  if steps <= 0 and self.spin_t then return end
  self.spin_t = (self.spin_t or now) + steps * 0.05
  local slew = self.cfg.prop_slew
  for _, id in ipairs(M.ORDER) do
    local c = self.ch[id]
    local target = c.applied or 0
    local p = c.prop or target
    for _ = 1, steps do
      p = p + util.clamp((target - p) / 2, -slew, slew)
    end
    c.prop = p
  end
end

-- Modelled RPM the props behind motor id are really turning at.
function M:prop(id, now)
  if now then self:spin(now) end
  return self.ch[id].prop or self.ch[id].applied or 0
end

-- One collective RPM for a group: the RPM that, on every motor of the group,
-- makes the same total force (mean of rpm|rpm|). With now: the modelled prop
-- spin; without: the RPM on the motors.
function M:effective(group, now)
  local ids = M.GROUPS[group]
  local sum = 0
  for _, id in ipairs(ids) do
    local v = now and self:prop(id, now) or self:applied(id)
    sum = sum + util.ssq(v)
  end
  return util.ssqrt(sum / #ids)
end

-- Next value to write for channel c, or nil.
-- in_batch: candidate for a coordinated batch, so ignore deadband and check
-- the whole batch's interval eligibility in group_due before starting it.
function M:next_value(c, now, in_batch)
  if c.desired == nil or c.dev == nil then return nil end
  local have = c.applied
  if self.urgent and c.desired == 0 and have ~= 0 then return 0 end
  local want = c.desired
  if have == want then return nil end
  if not in_batch and now - c.last_write + 1e-6 < self.cfg.min_interval[c.group] then return nil end
  if have == nil then
    -- Unknown motor state (getSpeed failed): write the target as is.
    return want
  end
  local delta = want - have
  -- Deadband only between two running speeds: starting or stopping is always
  -- written. DEBUG (self.exact) writes exactly what it asks for.
  if not in_batch and not self.exact and want ~= 0 and have ~= 0
    and math.abs(delta) < self.cfg.deadband[c.group] then
    return nil
  end
  local slew = self.cfg.slew[c.group]
  local v = have + util.clamp(delta, -slew, slew)
  -- Reversing: stop at 0 on the way through, and never spend a write
  -- interval on a residue short of 0 (884 -> 484 -> 84 -> 0 -> -400).
  if have ~= 0 and want ~= 0 and util.sign(want) ~= util.sign(have) and math.abs(v) < slew / 2 then v = 0 end
  if have ~= 0 and v ~= 0 and util.sign(v) ~= util.sign(have) then v = 0 end
  return v
end

local function write(self, c, v, now)
  c.last_write = now
  c.writes = c.writes + 1
  local ok, err = pcall(c.dev.setSpeed, v * c.sign)
  -- setSpeed yields on the server thread. Pace from completion, not from
  -- the stale timestamp captured before that yield.
  c.last_write = math.max(now, self.clock())
  if ok then
    c.applied = v
    c.fault = nil
  else
    c.applied = nil
    c.fault = tostring(err)
  end
  return c.id
end

-- The writes for group name to make now, or nil: { id =, v = } for the
-- motors turning down (or, if none, the ones turning up). Every member must
-- be ready before any is written, preserving both cadence and paired motion.
function M:group_due(name, now)
  local due = false
  local down, up = {}, {}
  for _, id in ipairs(M.GROUPS[name]) do
    local c = self.ch[id]
    if self:next_value(c, now) ~= nil then due = true end
    local v = self:next_value(c, now, true)
    if v ~= nil then
      local list = math.abs(v) < math.abs(c.applied or 0) and down or up
      list[#list + 1] = { id = id, v = v }
    end
  end
  if not due then return nil end
  local list = #down > 0 and down or up
  if #list == 0 then return nil end
  for i, w in ipairs(list) do
    local c = self.ch[w.id]
    -- Each peripheral write occupies at least one server tick. Check each
    -- member's earliest write slot, not all members against the first slot.
    if now + (i - 1) * 0.05 - c.last_write + 1e-6 < self.cfg.min_interval[name] then return nil end
  end
  return list
end

-- Write at most one motor. Returns the channel id written, or nil.
-- setSpeed runs on the server thread, so in game this call yields.
function M:service(now)
  self:spin(now)
  -- Emergency zeros first.
  if self.urgent then
    for _, id in ipairs(M.ORDER) do
      local c = self.ch[id]
      if c.dev and c.applied ~= 0 and c.desired == 0 then return write(self, c, 0, now) end
    end
    self.urgent = false
  end

  -- A running group batch goes on, one motor per tick, with the values
  -- chosen when it started, so motors that move together stay equal.
  while #self.batch > 0 do
    local w = self.batch[1]
    local c = self.ch[w.id]
    if c.dev and c.desired ~= nil and c.applied ~= w.v then
      if now - c.last_write + 1e-6 < self.cfg.min_interval[c.group] then return nil end
      table.remove(self.batch, 1)
      return write(self, c, w.v, now)
    end
    table.remove(self.batch, 1)
  end

  -- Otherwise the lift, then the largest weighted need. A lift trim (no
  -- corner moving by twice the lift deadband) waits its turn like the
  -- others: holding altitude closed-loop trims the lift often.
  local best, best_need = nil, -1
  for _, name in ipairs({ "lift", "rcs", "thrust" }) do
    local list = self:group_due(name, now)
    if list then
      local need, step = 0, 0
      for _, w in ipairs(list) do
        local c = self.ch[w.id]
        need = math.max(need, math.abs((c.desired or 0) - (c.applied or 0)) / c.cap * self.cfg.weight[name])
        step = math.max(step, math.abs(w.v - (c.applied or 0)))
      end
      if name == "lift" and step >= 2 * self.cfg.deadband.lift then need = need + 1000 end
      if need > best_need then best, best_need = list, need end
    end
  end
  if not best then return nil end
  self.batch = {}
  for i = 2, #best do self.batch[#self.batch + 1] = best[i] end
  local first = best[1]
  return write(self, self.ch[first.id], first.v, now)
end

function M:snapshot(now)
  local out = {}
  for _, id in ipairs(M.ORDER) do
    local c = self.ch[id]
    out[id] = {
      label = c.label,
      cap = c.cap,
      des = c.desired,
      app = c.applied,
      writes = c.writes,
      fault = c.fault,
      present = c.dev ~= nil,
    }
  end
  return out
end

-- Warnings about the motors for the displays.
function M:alerts(now)
  local list = {}
  for _, id in ipairs(M.ORDER) do
    local c = self.ch[id]
    if c.dev == nil then list[#list + 1] = "MISSING " .. c.label end
    if c.fault then list[#list + 1] = c.label .. " WRITE FAILED" end
  end
  return list
end

return M
