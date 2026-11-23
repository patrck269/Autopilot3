-- Station keeping: hold the hull on a world point (x, z) to within a
-- fraction of a block, fore/aft with the pushers and sideways with the RCS,
-- without turning. It runs continuously (no rest band): with the helm brake
-- off the hull has almost no drag, so any rest lets it drift.
--
-- Per body axis it steers on where the hull will be `lead` s from now
-- (pushers and RCS answer late: a server delay, paced writes and prop spin),
-- asks for a speed toward the point (capped, and slowing at plan_accel), and
-- turns the speed error into an acceleration:
--   a = vel_gain * (v_wanted - v_predicted) + integral
-- capped at max_accel. The integral (world frame, so a turn keeps it)
-- cancels steady pushes such as a slight tilt of the lift.
--
-- The pushers' and the RCS's real strength at these small forces has been
-- measured in game at a quarter to four times what the speed loop learned at
-- cruise forces, and a hold tuned for one swings or crawls with the other.
-- So each axis learns its own gain: the acceleration the hull really showed
-- over 0.5 s windows against the acceleration the props were modelled to
-- give (delayed by `delay` s), plus a slow bias, by least squares.
local util = require("ap3.util")
local rls = require("ap3.rls")

local M = {}
M.__index = M

local AXES = { "f", "s" } -- f: along the bow (pushers), s: to starboard (RCS)

function M.new(cfg)
  local self = setmetatable({ c = cfg.station, ix = 0, iz = 0, hist = {}, win = nil, gain = {}, est = {} }, M)
  for _, k in ipairs(AXES) do
    self.gain[k] = 1
    self.est[k] = rls.new({ 1, 0 }, { 4, 0.01 }, cfg.station.learn_forget)
  end
  return self
end

-- Forget the integral (a new point or a new mode). The learned gains stay.
function M:reset()
  self.ix, self.iz = 0, 0
  self.win = nil
end

local function toward(e, vmax, c)
  local m = math.abs(e)
  return util.sign(e) * math.min(vmax, c.pos_gain * m, math.sqrt(2 * c.plan_accel * m))
end

-- Mean modelled acceleration per axis over [t0, t1] of the history.
function M:modelled(t0, t1)
  local sum, n = { f = 0, s = 0 }, 0
  for _, h in ipairs(self.hist) do
    if h.t >= t0 and h.t <= t1 then
      sum.f, sum.s, n = sum.f + h.f, sum.s + h.s, n + 1
    end
  end
  if n == 0 then return nil end
  return { f = sum.f / n, s = sum.s / n }
end

-- Learn each axis' gain from the last window (see the header).
-- a_prop: modelled acceleration from the props' current spin per axis.
function M:observe(s, now, a_prop)
  local c = self.c
  local hist = self.hist
  hist[#hist + 1] = { t = now, f = a_prop.f, s = a_prop.s }
  while #hist > 0 and hist[1].t < now - c.delay - 2 * c.learn_window do table.remove(hist, 1) end
  local w = self.win
  if not w then
    self.win = { t0 = now, vx = s.vx, vz = s.vz }
    return
  end
  if now - w.t0 < c.learn_window then return end
  self.win = { t0 = now, vx = s.vx, vz = s.vz }
  local x = self:modelled(w.t0 - c.delay, now - c.delay)
  if not x then return end
  local h = math.rad(s.hdg)
  local dvx, dvz = (s.vx - w.vx) / (now - w.t0), (s.vz - w.vz) / (now - w.t0)
  local y = { f = dvx * math.sin(h) - dvz * math.cos(h), s = dvx * math.cos(h) + dvz * math.sin(h) }
  for _, k in ipairs(AXES) do
    -- Too little modelled force: the window shows only disturbances.
    if math.abs(x[k]) >= c.learn_min_accel then
      local est = self.est[k]
      est:update({ x[k], 1 }, y[k])
      est.t[1] = util.clamp(est.t[1], c.min_gain, c.max_gain)
      est.t[2] = util.clamp(est.t[2], -c.int_limit, c.int_limit)
      self.gain[k] = est.t[1]
    end
  end
end

-- s: telemetry. A: pusher m/s^2 at full (speed loop); auth: sway m/s^2 at
-- full. f_prop, sw_prop: normalised pusher and sway force the props make
-- now (modelled spin); pend_f, pend_sw: force set but not yet reaching them.
-- Returns pusher force f and sway force sw (normalised) and the distance.
function M:command(s, x, z, dt, now, A, auth, f_prop, sw_prop, pend_f, pend_sw)
  local c = self.c
  local A_f, A_s = A * self.gain.f, auth * self.gain.s
  self:observe(s, now, { f = A * f_prop, s = auth * sw_prop })

  local h = math.rad(s.hdg)
  local fx, fz = math.sin(h), -math.cos(h) -- bow
  local rx, rz = math.cos(h), math.sin(h)  -- starboard
  local dx, dz = x - s.x, z - s.z
  local d = math.sqrt(dx * dx + dz * dz)

  -- Integral in the world frame, only close to the point (a move would
  -- wind it up), held while the output is capped.
  if d < c.int_zone and not self.capped then
    self.ix = self.ix + c.int_gain * dx * dt
    self.iz = self.iz + c.int_gain * dz * dt
    local m = math.sqrt(self.ix * self.ix + self.iz * self.iz)
    if m > c.int_limit then
      self.ix, self.iz = self.ix * c.int_limit / m, self.iz * c.int_limit / m
    end
  end

  local function axis(e, v, pend_a, vmax, i)
    local e_p = e - v * c.lead
    local v_p = v + pend_a * c.lead
    return c.vel_gain * (toward(e_p, vmax, c) - v_p) + i
  end
  local a_f = axis(dx * fx + dz * fz, s.v_fwd, A_f * (pend_f or 0), c.fwd_max, self.ix * fx + self.iz * fz)
  local a_s = axis(dx * rx + dz * rz, s.v_side, A_s * (pend_sw or 0), c.side_max, self.ix * rx + self.iz * rz)
  self.capped = math.abs(a_f) > c.max_accel or math.abs(a_s) > c.max_accel
  a_f = util.clamp(a_f, -c.max_accel, c.max_accel)
  a_s = util.clamp(a_s, -c.max_accel, c.max_accel)
  self.a_f, self.a_s = a_f, a_s
  return a_f / A_f, a_s / A_s, d
end

return M
