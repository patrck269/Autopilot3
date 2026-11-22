-- Point navigation: fly to a world point, end there at a set altitude and
-- bearing, and hold position. Named waypoints and a multi-leg route.
--
-- A leg is { x =, z =, y = nil|n, brg = nil|n, name = nil|s }. A stop is a
-- leg with a bearing, and always the last leg; any other leg is flown
-- through. y = nil sets no altitude for the leg.
--
-- Each leg climbs first and descends last: the ship cruises at the highest
-- of its altitude, the leg's and min_transit_alt (out of reach of ground
-- fire), and only descends to a stop's Y once over it. A stop without Y is
-- held at the transit altitude.
--   CLIMB    to the transit altitude, turning toward the point, no speed
--   TRANSIT  bow on the point; speed brakes along sqrt(2 a d) to the next stop
--   HOLD     at a stop: translate fore/aft (pushers) and sideways (RCS)
--            onto the point without turning, descend, turn to the bearing;
--            settled there for settle_time, the next leg starts
--   ARRIVED  the last stop reached: keeps holding
-- A stop closer than translate_radius when its leg starts is reached in
-- HOLD alone (no turn toward it).
local util = require("ap3.util")

local M = {}
M.__index = M

local atan2 = math.atan2 or math.atan
local DEG = 180 / math.pi
-- The transit braking profile falls at brake_accel; the speed reference
-- may ramp this many times faster, so it catches the profile instead of
-- trailing it into an overshoot of the stop.
local CATCH = 2

M.NAME_ERROR = "waypoint names: a letter, then letters, digits, - or _ (max 12)"

function M.valid_name(name)
  return type(name) == "string" and #name <= 12 and name:match("^[a-z][a-z0-9_-]*$") ~= nil
end

local function optional(v)
  return v == nil or util.finite(v)
end

-- A clean copy of leg t, or nil when it is not a usable leg.
local function clean(t, name)
  if type(t) ~= "table" or not util.finite(t.x) or not util.finite(t.z)
    or not optional(t.y) or not optional(t.brg) then
    return nil
  end
  if name ~= nil and not M.valid_name(name) then return nil end
  return { x = t.x, z = t.z, y = t.y, brg = t.brg and t.brg % 360 or nil, name = name }
end

local function copy(leg)
  return { x = leg.x, z = leg.z, y = leg.y, brg = leg.brg, name = leg.name }
end

local function dist(ax, az, bx, bz)
  return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

-- Magnitude-limited translation speed toward a point e blocks away.
local function toward(e, vmax, c)
  local m = math.abs(e) - c.hold_margin
  if m <= 0 then return 0 end
  return util.sign(e) * math.min(vmax, c.hold_gain * m, math.sqrt(2 * c.hold_accel * m))
end

-- Position hold by translation: the fore/aft speed (pushers) and sideways
-- speed (RCS) that move the hull from s onto world point (x, z) without
-- turning. state.hold_on carries the engage/settle hysteresis. Returns spd,
-- side (m/s, starboard positive) and the distance.
function M.translate(c, state, x, z, s)
  local dx, dz = x - s.x, z - s.z
  local d = math.sqrt(dx * dx + dz * dz)
  local h = math.rad(s.hdg)
  local along = dx * math.sin(h) - dz * math.cos(h)
  local side = dx * math.cos(h) + dz * math.sin(h)
  if d > c.hold_engage then
    state.hold_on = true
  elseif d < c.hold_settle and s.gs < 0.3 then
    state.hold_on = false
  end
  if not state.hold_on then return 0, 0, d end
  -- Steer on where the hull will be once the pushers and RCS have answered
  -- (hold_lead s), not where it is: that damps the overshoot.
  return toward(along - c.hold_lead * s.v_fwd, c.hold_fwd_max, c),
    toward(side - c.hold_lead * s.v_side, c.hold_side_max, c), d
end

-- saved: the /ap3_nav.dat table ({ points =, route = }) or nil.
function M.new(cfg, saved)
  local c = cfg.nav
  local self = setmetatable({
    c = c,
    points = {},
    route = {},
    active = nil,
    i = nil,
    phase = nil,
    speed = c.speed,
    transit_alt = nil,
    hold_on = false,
    settled_since = nil,
    last = nil,
  }, M)
  if type(saved) == "table" then
    if type(saved.points) == "table" then
      local names = {}
      for name in pairs(saved.points) do
        if type(name) == "string" then names[#names + 1] = name end
      end
      table.sort(names)
      local n = 0
      for _, name in ipairs(names) do
        local leg = clean(saved.points[name], name)
        if leg and n < c.max_points then
          self.points[name] = leg
          n = n + 1
        end
      end
    end
    if type(saved.route) == "table" then
      for _, t in ipairs(saved.route) do
        local leg = type(t) == "table" and clean(t, t.name)
        if leg and #self.route < c.max_legs then self.route[#self.route + 1] = leg end
      end
    end
  end
  return self
end

function M:saved()
  local points, route = {}, {}
  for name, leg in pairs(self.points) do points[name] = copy(leg) end
  for i, leg in ipairs(self.route) do route[i] = copy(leg) end
  return { points = points, route = route }
end

-- Sorted waypoint names.
function M:names()
  local list = {}
  for name in pairs(self.points) do list[#list + 1] = name end
  table.sort(list)
  return list
end

-- A leg from a command operand: { x, z, y, brg } or { name }.
-- Returns leg or nil, error.
function M:resolve(v)
  if type(v) ~= "table" then return nil, "goto X Z [Y] [BRG] | goto <name>" end
  if v.name ~= nil then
    local p = self.points[v.name]
    if not p then return nil, "no waypoint " .. tostring(v.name) end
    return copy(p)
  end
  local leg = clean(v)
  if not leg then return nil, "goto X Z [Y] [BRG] | goto <name>" end
  return leg
end

function M:count_points()
  local n = 0
  for _ in pairs(self.points) do n = n + 1 end
  return n
end

-- Leg label for lists: its name, or x,z.
function M.label(leg)
  return leg.name or (util.fmt(leg.x, 0) .. "," .. util.fmt(leg.z, 0))
end

function M:is_stop(i)
  local leg = self.active[i]
  return leg.brg ~= nil or i == #self.active
end

function M:enter_hold(leg, s)
  self.phase = "HOLD"
  self.hold_brg = leg.brg or util.round(s.hdg) % 360
  self.hold_on = true
  self.settled_since = nil
  self.over = false -- set once over the point: the descent is not undone by a drift
  self.pause_alt = nil
end

-- Start leg self.i from state s. Fly-throughs already inside pass_radius
-- are skipped.
function M:begin_leg(s)
  local c = self.c
  while true do
    local leg = self.active[self.i]
    local d = dist(leg.x, leg.z, s.x, s.z)
    if self.i == 1 or self:is_stop(self.i - 1) then
      self.transit_alt = math.max(util.round(s.y), leg.y or -math.huge)
    else
      self.transit_alt = math.max(self.transit_alt, leg.y or -math.huge)
    end
    self.settled_since = nil
    local stop = self:is_stop(self.i)
    if stop and d <= c.translate_radius then
      self:enter_hold(leg, s)
      return
    elseif not stop and d <= c.pass_radius then
      self.i = self.i + 1
    else
      self.phase = "CLIMB"
      self.transit_alt = math.max(self.transit_alt, c.min_transit_alt)
      return
    end
  end
end

-- Start flying list (a list of legs, kept by reference).
function M:start(list, s)
  self.active = list
  self.i = 1
  self.hold_on = false
  self.docking = false
  self:begin_leg(s)
end

-- Docking: hold at leg by translation alone, however far it is (no climb
-- to the transit floor, no transit).
function M:dock(leg, s)
  self.active, self.i = { leg }, 1
  self.transit_alt = math.max(util.round(s.y), leg.y or -math.huge)
  self:enter_hold(leg, s)
  self.docking = true
end

-- The point a docking move starts from while the last leg is held (its
-- position, altitude and bearing), else nil.
function M:hold_point()
  if self.active and (self.phase == "HOLD" or self.phase == "ARRIVED") and self.i == #self.active then
    local leg = self.active[self.i]
    return { x = leg.x, z = leg.z, y = leg.y, brg = self.hold_brg }
  end
  return nil
end

function M:stop()
  self.active, self.i, self.phase, self.last = nil, nil, nil, nil
  self.settled_since = nil
  self.docking = false
end

-- Remaining distance: to leg i, then along the legs up to the next stop.
function M:remaining(d)
  local remain = d
  local i = self.i
  while not self:is_stop(i) do
    local a, b = self.active[i], self.active[i + 1]
    remain = remain + dist(a.x, a.z, b.x, b.z)
    i = i + 1
  end
  return remain
end

-- One control step while NAV flies. Returns { alt, brg, spd, rate, side }:
-- target altitude, bearing, forward speed (m/s), the slowest ramp for that
-- speed (m/s^2, or nil) and the sideways velocity target (m/s to starboard).
function M:step(s, now)
  local c = self.c
  local leg = self.active[self.i]
  local h = math.rad(s.hdg)
  local dx, dz = leg.x - s.x, leg.z - s.z
  local d = math.sqrt(dx * dx + dz * dz)
  local brg_to = (atan2(dx, -dz) * DEG) % 360
  local along = dx * math.sin(h) - dz * math.cos(h)
  local side = dx * math.cos(h) + dz * math.sin(h)
  local remain = self:remaining(d)
  local cmd

  if self.phase == "CLIMB" and math.abs(s.y - self.transit_alt) <= c.climb_band then
    self.phase = "TRANSIT"
  end
  if self.phase == "TRANSIT" then
    if self:is_stop(self.i) then
      if d <= c.capture then self:enter_hold(leg, s) end
    elseif d <= c.pass_radius then
      self.i = self.i + 1
      self:begin_leg(s)
      return self:step(s, now)
    end
  end

  if self.phase == "CLIMB" then
    cmd = { alt = self.transit_alt, brg = brg_to, spd = 0, side = 0 }
  elseif self.phase == "TRANSIT" then
    local v = math.min(self.speed, math.sqrt(2 * c.brake_accel * math.max(remain - c.stop_margin, 0)))
    local off = math.abs(util.wrap180(brg_to - s.hdg))
    cmd = { alt = self.transit_alt, brg = brg_to, spd = off > c.align_deg and 0 or v,
      rate = CATCH * c.brake_accel, side = 0 }
  else
    -- HOLD / ARRIVED: descend last, translate onto the point, turn in place.
    -- Once over the point (within 3 blocks) the descent starts; drifted
    -- further out it pauses where it is, and goes on when back over it.
    local alt = self.transit_alt
    if d <= 3 then self.over, self.pause_alt = true, nil end
    if leg.y ~= nil and leg.y >= self.transit_alt then
      alt = leg.y
    elseif leg.y ~= nil and self.over then
      if d > 3 then
        self.pause_alt = self.pause_alt or util.round(s.y)
        alt = math.max(self.pause_alt, leg.y)
      else
        alt = leg.y
      end
    end
    local spd, sway = M.translate(c, self, leg.x, leg.z, s)
    cmd = { alt = alt, brg = self.hold_brg, spd = spd, rate = c.hold_accel, side = sway }
    if self.phase == "HOLD" then
      local settled = d <= c.hold_engage and math.abs(util.wrap180(self.hold_brg - s.hdg)) <= 2
        and math.abs(s.y - alt) <= 1.5
      if not settled then
        self.settled_since = nil
      else
        self.settled_since = self.settled_since or now
        if now - self.settled_since >= c.settle_time then
          if self.i < #self.active then
            self.i = self.i + 1
            self:begin_leg(s)
            return self:step(s, now)
          end
          self.phase = "ARRIVED"
        end
      end
    end
  end

  self.last = {
    phase = self.phase, i = self.i, n = #self.active, leg = leg, d = d, brg_to = brg_to,
    remain = remain, along = along, side = side, eta = remain / math.max(s.gs, 1),
  }
  return cmd
end

return M
