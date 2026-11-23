-- Heading hold and sideslip cancelling on the four RCS pullers.
--
-- The RCS only ever pulls (positive RPM); no controller reverses. Corner
-- forces for a turn force u (> 0 = right) and a sway force s (> 0 = toward
-- starboard), each corner clamped at 0:
--   bow stbd = u + s    stern port = u - s
--   bow port = -u - s   stern stbd = s - u
-- A pure turn is a diagonal pair (right: bow stbd + stern port), a pure
-- strafe a same-side pair (starboard: bow stbd + stern stbd), and any blend
-- gives exactly 2u of turn and 2s of sway.
--
-- Positive RPM pulls on all four corners (checked in game with DEBUG), so the
-- directions are fixed: only the turning strength is learned. Every 0.5 s the
-- measured yaw acceleration is fitted to yaw_accel = b * u - d * yaw_rate
-- (u = turn force the props are really applying), with b kept between
-- min_authority and max_authority. Only windows with a real turn force
-- (|u| >= learn_min_force) are fitted: with almost no turn force, a yaw from
-- anything else (an off-centre rear thrust line, a bump) would be credited to
-- the RCS and inflate b, and the smaller commands that follow can never
-- correct it. Commands are computed as an acceleration and divided by b.
--
-- Heading: bearing error sets a yaw-rate command; a PI loop on yaw rate gives
-- the yaw acceleration. The integral holds off steady torques such as a rear
-- thrust line that misses the centre of mass. A correction starts past the
-- deadzone and stops within settle_deg; in between the learned trim is held.
--
-- Sideslip: the brake holds sideways velocity at 0 outside station keeping
-- (which sets the sideways force itself, ap3/station.lua). An error past
-- sway_engage starts it; it runs until the error is under sway_settle, and
-- stops early when the props' remaining spin will finish the job (they take
-- over a second to spin down). The sideways strength comes from
-- ap3/motion.lua. Heading has first call on the RCS and sway gets what is
-- left, except while the hull slides faster than turn_yield_drift: then the
-- turn slows to turn_yield_rate and sway goes first. Turning and sideways
-- strength are kept at sea-level air density.
local util = require("ap3.util")
local rls = require("ap3.rls")

local M = {}
M.__index = M

-- saved: { yaw_b =, rcs_cap = } learned on an earlier flight, or nil.
-- Turning strength is kept at sea-level air density (RCS thrust goes with
-- the density); sea_rho: air density at sea level.
function M.new(cfg, saved, sea_rho)
  local c = cfg.heading
  local guess = c.yaw_authority
  local loaded = false
  if saved and util.finite(saved.yaw_b) and saved.yaw_b > 0 then
    -- Authority is defined at full normalised force. Preserve an old
    -- calibration when the RPM cap changes: prop force scales with RPM^2.
    local old_cap = util.finite(saved.rcs_cap) and saved.rcs_cap > 0 and saved.rcs_cap or 1000
    local new_cap = cfg.motors.bow_port.cap
    local b = saved.yaw_b * (new_cap / old_cap) ^ 2
    -- Past the maximum it was learned from noise: start again from the guess.
    if b >= c.min_authority and b <= c.max_authority then
      guess = b
      loaded = true
    end
  end
  return setmetatable({
    c = c, loaded = loaded, sea = sea_rho or 1,
    -- Wide starting variance: the real strength may be many times the guess.
    yaw = rls.new({ guess, 0.1 }, { math.max(100, 100 * guess * guess), 0.25 }, 0.95),
    integ = 0, err = 0, r_cmd = 0, win = nil,
    active = true, sway_active = false, drift = 0,
  }, M)
end

-- Turning strength: deg/s^2 at full turn force, at sea-level density.
function M:authority()
  return math.max(self.yaw.t[1], self.c.min_authority)
end

-- Air density relative to sea level at the hull.
function M:density(s)
  return util.clamp((s.rho or self.sea) / self.sea, 0.05, 2)
end

-- Engaging a mode or switching the bow axis: start the loops afresh.
function M:reset()
  self.integ = 0
  self.sway_active = false
end

-- Learn the turning authority from 0.5 s windows. u is the turn force the
-- props are really applying.
function M:observe(s, u, now)
  local w = self.win
  if w == nil then
    self.win = { t0 = now, r0 = s.yaw_rate, u = 0, r = 0, n = 0 }
    return
  end
  w.u, w.r, w.n = w.u + u, w.r + s.yaw_rate, w.n + 1
  local span = now - w.t0
  if span < 0.5 then return end
  self.win = { t0 = now, r0 = s.yaw_rate, u = 0, r = 0, n = 0 }

  local mu, mr = w.u / w.n, w.r / w.n
  if math.abs(mu) < self.c.learn_min_force then return end
  local l = self.yaw
  l:update({ mu * self:density(s), -mr }, (s.yaw_rate - w.r0) / span)
  l.t[1] = util.clamp(l.t[1], self.c.min_authority, self.c.max_authority)
  if l.t[2] < 0 then l.t[2] = 0 end
end

-- Returns the turn force u and the sway force sw, both normalised.
-- deadzone: bearing error (deg) tolerated before an active correction starts.
-- sway: { drift = m/s toward starboard, target = wanted m/s toward starboard
-- (nil = 0), auth = m/s^2 at full sway force, limit = largest sway force
-- allowed, coming = m/s the props' current spin will still add to the drift,
-- force = normalised sway force station keeping wants (then used as is) }
-- or nil to leave sideslip alone.
-- pending: turn force the motors are set to but the props have not yet
-- reached (they spin up and down at 32 RPM a tick); it adds a lead to the
-- yaw-rate loop so it does not keep pushing what is already on its way.
function M:command(s, bearing, dt, deadzone, sway, pending)
  local c = self.c
  local err = util.wrap180(bearing - s.hdg)
  local dist = math.abs(err)
  local b = self:authority() * self:density(s)
  local rate = s.yaw_rate + (pending and b * pending * c.yaw_lag or 0)
  -- Sliding sideways faster than turn_yield_drift: the RCS pair that turns
  -- the hull also pushes it sideways (a 140 deg turn in place moved it 30
  -- blocks in game), so the turn slows to turn_yield_rate and the sideways
  -- force gets first call on the RCS.
  local yielding = sway ~= nil and math.abs(sway.drift - (sway.target or 0)) > c.turn_yield_drift
  local max_rate = yielding and math.min(c.max_rate, c.turn_yield_rate) or c.max_rate

  if self.active then
    if dist < c.settle_deg and math.abs(s.yaw_rate) < c.settle_rate then self.active = false end
  elseif dist > deadzone or math.abs(s.yaw_rate) > c.engage_rate then
    self.active = true
  end

  local u
  if not self.active then
    self.r_cmd = 0
    u = util.clamp(self.integ / b, -1, 1)
  else
    local decel = math.min(c.yaw_accel, 0.5 * b)
    local r_cmd = util.sign(err) * math.min(max_rate, c.bearing_gain * dist, math.sqrt(2 * decel * dist))
    local r_err = r_cmd - rate
    local int_gain = c.int_gain
    if s.gs > c.high_speed then int_gain = int_gain * c.high_speed_gain end
    local grown = util.clamp(self.integ + int_gain * r_err * dt, -c.int_limit, c.int_limit)
    -- No wind-up while the output is pinned at its limit.
    local u_try = (grown + c.rate_gain * r_err) / b
    if math.abs(u_try) < 1 or math.abs(grown) < math.abs(self.integ) then self.integ = grown end
    self.r_cmd = r_cmd
    u = util.clamp((self.integ + c.rate_gain * r_err) / b, -1, 1)
  end
  self.err = err

  -- The turn and the sideways force share the RCS: normally the turn has
  -- first call, while yielding the sideways force does.
  local function share(u0, sw0)
    if yielding then
      return util.clamp(u0, -(1 - math.abs(sw0)), 1 - math.abs(sw0)), sw0
    end
    local room = 1 - math.abs(u0)
    return u0, util.clamp(sw0, -room, room)
  end

  -- Sideslip brake with engage/settle hysteresis, on the drift the hull will
  -- have once the props' current spin has played out.
  local sw = 0
  self.drift = 0
  if sway and sway.force then
    -- Station keeping computes the sway force itself (ap3/station.lua).
    self.drift = sway.drift
    self.sway_active = sway.force ~= 0
    local slimit = sway.limit or 1
    return share(u, util.clamp(sway.force, -slimit, slimit))
  end
  if sway then
    local err = sway.drift - (sway.target or 0)
    local ahead = err + (sway.coming or 0)
    self.drift = sway.drift
    if self.sway_active then
      if math.abs(ahead) < c.sway_settle or math.abs(err) < c.sway_settle then self.sway_active = false end
    elseif math.abs(err) > c.sway_engage then
      self.sway_active = true
    end
    if self.sway_active then
      local auth = math.max(sway.auth, c.min_sway_authority)
      local slimit = sway.limit or 1
      sw = util.clamp(-c.sway_gain * ahead / auth, -slimit, slimit)
    end
  end
  return share(u, sw)
end

-- Turn and sway forces from four corner RPMs.
function M.applied(rpm, caps)
  local function f(id) return util.ssq(rpm[id] or 0) / (caps[id] * caps[id]) end
  local bs, sp, bp, ss = f("bow_stbd"), f("stern_port"), f("bow_port"), f("stern_stbd")
  return (bs + sp - bp - ss) / 2, (bs + ss - bp - sp) / 2
end

-- Map turn and sway forces to the four pullers' RPM (pull only). Corners
-- under min_rpm are sent as 0.
function M.mix(u, sw, caps, min_rpm)
  local force = {
    bow_stbd = u + sw, stern_port = u - sw,
    bow_port = -u - sw, stern_stbd = sw - u,
  }
  local rpm = {}
  for id, f in pairs(force) do
    local r = math.sqrt(util.clamp(f, 0, 1)) * caps[id]
    if r < min_rpm then r = 0 end
    rpm[id] = r
  end
  return rpm
end

function M:saved()
  return { yaw_b = (self.loaded or self.yaw.count > 0) and self:authority() or nil }
end

return M
