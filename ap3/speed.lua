-- Signed forward-speed control on the rear thrusters: positive RPM pushes
-- forward; negative RPM brakes forward motion or drives the hull astern.
--
-- A speed reference ramps from the current speed to the target at a rate that
-- arrives in ramp_time seconds (inside the 15 s requirement); the controller
-- tracks the reference. Propeller force goes with RPM squared, so control
-- works on normalised force f = rpm|rpm| / cap^2 in [-1, 1] with the model
--     a = A * f - D * v|v|
-- A (acceleration at full thrust) and D (drag) are learned in flight by
-- recursive least squares, so the feed-forward fits the real hull and the
-- PI term only cleans up the remainder. Acceleration that pitches the nose past
-- pitch_limit holds the thrust back and pauses the ramp until it recovers.
local util = require("ap3.util")
local rls = require("ap3.rls")

local M = {}
M.__index = M

local S = 35 -- drag regressor scale, keeps both RLS columns near 1

function M.new(cfg, saved)
  local c = cfg.speed
  local A = c.accel_full
  local Dn = A * (S / c.top_speed) ^ 2
  -- A saved strength under min_accel_full was learned at the clamp (no real
  -- push measured): start from the first guess instead.
  if saved and util.finite(saved.A) and util.finite(saved.Dn) and saved.A >= c.min_accel_full then
    A, Dn = saved.A, saved.Dn
  end
  return setmetatable({
    c = c,
    A = A,
    write_rate = cfg.actuator.slew.thrust / cfg.actuator.min_interval.thrust,
    write_wait = cfg.actuator.min_interval.thrust,
    Dn = Dn,
    est = rls.new({ A, Dn }, { 4, 4 }, 0.98),
    target = 0,
    v_ref = 0,
    rate = c.min_ramp,
    integ = 0,
    pitch_hold = false,
    saturated = 0,
    win = nil,
    phase = "HOLD",
    a_ref = 0,
  }, M)
end

function M:drag(v)
  return self.Dn / (S * S) * v * math.abs(v)
end

-- The bow axis changed: what was learned along the old axis is wrong.
function M:forget(v_now)
  local c = self.c
  self.A = c.accel_full
  self.Dn = c.accel_full * (S / c.top_speed) ^ 2
  self.est = rls.new({ self.A, self.Dn }, { 4, 4 }, 0.98)
  self.win = nil
  self.held_f = nil
  self:reset(v_now)
end

-- Restart from the current speed (on engage) so there is no jump.
function M:reset(v_now)
  self.v_ref = v_now
  self.integ = 0
  self.pitch_hold = false
  self.held_f, self.resting, self.saturated = nil, false, 0
  self:set_target(self.target, v_now)
end

-- min_rate (optional): slowest reference ramp for this target, m/s^2.
function M:set_target(target, v_now, min_rate)
  -- Thrust is only rewritten about once a second, so the reference stops
  -- cap_margin short of the hard cap to keep the overshoot under it.
  local limit = self.c.max - self.c.cap_margin
  self.target = util.clamp(target or 0, -limit, limit)
  local gap = math.abs(self.target - self.v_ref)
  -- A stop must finish braking, not merely finish the reference ramp.
  local duration = self.target == 0 and math.max(self.c.ramp_time - self.c.thrust_lag, self.c.thrust_lag)
    or self.c.ramp_time
  self.rate = math.max(gap / duration, self.c.min_ramp, min_rate or 0)
end

-- Learn A and D from 0.5 s windows of measured acceleration.
function M:observe(s, applied_f, now)
  local w = self.win
  if w == nil then
    self.win = { t0 = now, v0 = s.v_fwd, f = 0, vv = 0, n = 0 }
    return
  end
  w.f = w.f + applied_f
  w.vv = w.vv + s.v_fwd * math.abs(s.v_fwd)
  w.n = w.n + 1
  local span = now - w.t0
  if span < 0.5 then return end
  self.win = { t0 = now, v0 = s.v_fwd, f = 0, vv = 0, n = 0 }

  local f = w.f / w.n
  local x2 = -(w.vv / w.n) / (S * S)
  if math.abs(f) < 0.02 and math.abs(x2) < 0.002 then return end -- nothing to learn from
  local y = (s.v_fwd - w.v0) / span

  self.est:update({ f, x2 }, y)
  local t = self.est.t
  t[1] = util.clamp(t[1], self.c.min_accel_full, 30)
  t[2] = util.clamp(t[2], 0, 60)
  self.A, self.Dn = t[1], t[2]
end

-- pending is commanded force minus force already reaching the hull. Account
-- for the velocity still arriving as the props spin to their motor speeds.
function M:command(s, dt, cap, applied_rpm, pending)
  local c = self.c
  local v = s.v_fwd
  local applied_f = util.ssq(applied_rpm or 0) / (cap * cap)
  local prop_f = applied_f - (pending or 0)
  -- Include the impulse left while paced writes ramp the motor to zero.
  -- RPM ramps linearly, so its squared force averages one third of full.
  local horizon = math.max(c.thrust_lag, math.abs(applied_rpm or 0) / (3 * self.write_rate))
  local coming = self.A * (pending or 0) * horizon
  local net_accel = self.A * prop_f - self:drag(v)

  local before = self.v_ref
  if not self.pitch_hold then
    self.v_ref = util.approach(self.v_ref, self.target, self.rate * dt)
  end
  self.a_ref = (self.v_ref - before) / dt

  local ahead = util.approach(self.v_ref, self.target, self.rate * horizon)
  local err = ahead - v - net_accel * horizon - coming
  local grow = c.int_gain * err * dt
  if not self.held_f and not (self.saturated ~= 0 and util.sign(grow) == self.saturated) then
    self.integ = util.clamp(self.integ + grow, -c.int_limit, c.int_limit)
  end

  -- Preview the end of the ramp: the pushers need paced writes to shed the
  -- acceleration thrust, so asking for it until arrival guarantees overshoot.
  local feed = self.a_ref
  if horizon > 0 then
    feed = self.pitch_hold and 0 or (ahead - self.v_ref) / horizon
  end
  local accel = feed + c.vel_gain * err + self.integ
  local f = (accel + self:drag(v)) / self.A
  self.saturated = 0
  if f > 1 then f = 1; self.saturated = 1 end
  if f < -1 then f = -1; self.saturated = -1 end

  -- Pitch protection: thrust along the hull pitches the nose when the line of
  -- thrust misses the centre of mass. Forward thrust dipping the nose (or
  -- reverse thrust raising it) toward the limit holds the thrust back: past
  -- the limit (with a pitch-rate lead) thrust is cut in proportion to the
  -- excess; until the nose is a degree back inside the limit it may not grow.
  local dir = util.sign(f)
  if dir == 0 then dir = util.sign(applied_f) end
  local dip = -s.pitch * dir
  local excess = dip - 0.7 * (s.pitch_rate or 0) * dir - c.pitch_limit
  if excess > 0 then
    self.pitch_hold = true
    local limit = math.abs(applied_f) * util.clamp(1 - 0.12 * excess, 0.3, 0.95)
    if math.abs(f) > limit then f = dir * limit end
  elseif self.pitch_hold then
    if excess < -1 then
      self.pitch_hold = false
    elseif math.abs(f) > math.abs(applied_f) then
      f = dir * math.abs(applied_f)
    end
  end

  -- Stopped (target 0): the rear thrusters rest until drift passes
  -- hover_engage, then brake it back under stop_band and rest again.
  if self.target == 0 and math.abs(self.v_ref) < 0.01 then
    if self.resting then
      if math.abs(v) > c.hover_engage then self.resting = false end
    elseif math.abs(v) < c.stop_band then
      self.resting = true
    end
  else
    self.resting = false
  end
  if self.resting then
    f = 0
    self.integ = 0
  end

  -- Steady at cruise speed: hold the thrust that balances drag (plus the
  -- learned trim) and stop rewriting it, until the speed drifts past
  -- hold_release, so the pushers are not rewritten every loop.
  -- Passing through the target while still accelerating is not settled.
  -- Use the force already at the props to preview capture and release.
  -- Inside hold_band for two write intervals also captures: the paced
  -- writes can otherwise swing the pushers one slew step up and down every
  -- write around the target, and the preview never settles.
  local projected = v + net_accel * horizon
  if self.target ~= 0 and math.abs(self.v_ref - self.target) < 0.01 and not self.pitch_hold then
    local inside = math.abs(v - self.target) < c.hold_band
    self.in_band = inside and (self.in_band or 0) + dt or 0
    if self.held_f then
      if math.max(math.abs(v - self.target), math.abs(projected - self.target)) > c.hold_release then
        self.held_f = nil
      else
        f = self.held_f
      end
    elseif inside and (math.abs(projected - self.target) < c.hold_band or self.in_band >= 2 * self.write_wait) then
      self.held_f = util.clamp((self:drag(self.target) + self.integ) / self.A, -1, 1)
      f = self.held_f
    end
  else
    self.held_f = nil
    self.in_band = 0
  end

  if self.pitch_hold then
    self.phase = "PITCH"
  elseif math.abs(self.v_ref - self.target) > 0.01 then
    self.phase = self.target * self.v_ref >= 0 and math.abs(self.target) > math.abs(self.v_ref) and "ACCEL" or "DECEL"
  else
    self.phase = "HOLD"
  end
  return util.ssqrt(f) * cap, f
end

function M:saved()
  return { A = self.A, Dn = self.Dn }
end

return M
