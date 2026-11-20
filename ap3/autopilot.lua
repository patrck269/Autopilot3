-- Autopilot modes and the glue between sensors, control loops and the motor bank.
--
--   STBY    autopilot off: pushers and RCS to 0, lift left as it is
--   HOVER   hold target altitude (climb/descend to it), brake to a stop with
--           reverse thrust, hold heading, damp sideways drift
--   CRUISE  hold target altitude and bearing, fly at target speed (cap 35 m/s,
--           reached through a ramp that arrives within 15 s), slow down with
--           reverse thrust, RCS keeps heading and cancels sideslip
--   NAV     fly to a point or along a route (ap3/nav.lua): climb first,
--           transit bow-on, translate onto the point, descend last, turn to
--           the final bearing and hold position there
--   KILL    every motor to 0 at once; stays until another mode is chosen
--   DEBUG   every motor at +debug_rpm as written to the block (the
--           config sign is not applied), to see which way each prop pushes.
--           The lift drops to that RPM too. Learning is paused.
local util = require("ap3.util")
local altitude = require("ap3.altitude")
local speed = require("ap3.speed")
local heading = require("ap3.heading")
local motion = require("ap3.motion")
local rcscheck = require("ap3.rcscheck")
local actuators = require("ap3.actuators")
local level = require("ap3.level")
local nav = require("ap3.nav")

local M = {}
M.__index = M

M.MODES = { STBY = true, HOVER = true, CRUISE = true, NAV = true, KILL = true, DEBUG = true }
-- Modes in which the autopilot flies the hull.
M.FLYING = { HOVER = true, CRUISE = true, NAV = true }
local RCS = actuators.GROUPS.rcs

-- saved: prior calibration ({ k =, A =, Dn =, yaw_b =, rcs_cap =, bow = }) or nil.
-- sea_rho: air density at sea level (seeds the hover guess).
-- tel: telemetry; the learned bow axis is applied to it.
-- opts: { rcs_off = true while the helm steers (survives a reboot),
--         nav = saved waypoints and route } or nil.
function M.new(cfg, saved, sea_rho, tel, opts)
  if saved and type(saved.bow) == "table" and util.finite(saved.bow.x) then
    tel.set_forward(saved.bow)
  end
  local self = setmetatable({
    cfg = cfg,
    tel = tel,
    mode = "STBY",
    tgt = { alt = nil, brg = nil, spd = 0 },
    alt = altitude.new(cfg, saved, sea_rho),
    spd = speed.new(cfg, saved),
    hdg = heading.new(cfg, saved),
    motion = motion.new(cfg, tel),
    level = level.new(cfg),
    nav = nav.new(cfg, opts and opts.nav),
    sway_target = nil, -- NAV HOLD: sideways velocity target, m/s to starboard
    rcs_off = opts ~= nil and opts.rcs_off == true,
    bow_learned = saved ~= nil and saved.bow ~= nil,
    rcs_map = saved and saved.rcs_map or nil, -- RCS layout from an earlier check (applied at start-up)
    rcs_found = nil,                           -- a differing layout found by the last check
    caps = {},
    accel_limited_since = nil,
    events = {},
  }, M)
  for id, c in pairs(cfg.motors) do self.caps[id] = c.cap end
  return self
end

function M:log(text)
  local e = self.events
  e[#e + 1] = text
  if #e > 12 then table.remove(e, 1) end
end

function M:engage(mode, s)
  local prev = self.mode
  self.mode = mode
  if self.check then
    self.check = nil
    self:log("RCS CHECK STOPPED")
  end
  if prev == "NAV" and mode ~= "NAV" then
    if self.nav.active then self:log("NAV ENDED") end
    self.nav:stop()
  end
  self.sway_target = nil
  self.nav_sent = nil
  -- Learning pauses in KILL and DEBUG; start fresh windows either side.
  self.alt.win, self.spd.win, self.hdg.win, self.motion.win = nil, nil, nil, nil
  if M.FLYING[mode] then
    if self.tgt.alt == nil then self.tgt.alt = util.round(s.y) end
    if self.tgt.brg == nil then self.tgt.brg = util.round(s.hdg) % 360 end
    if not M.FLYING[prev] then
      self.hdg:reset()
      self.spd:reset(s.v_fwd)
      self.level:reset()
    end
    if mode == "CRUISE" then
      self.spd:set_target(self.tgt.spd, s.v_fwd)
    else
      self.spd:set_target(0, s.v_fwd)
    end
  end
  self:log("MODE " .. mode)
end

-- Start NAV on list (legs), or with dock = true hold list[1] by translation
-- alone. Returns ok, message.
function M:start_nav(list, s, dock)
  if self.rcs_off then return false, "rcs is off: type 'rcs on' first" end
  if self.alt.grounded then return false, "lift off first: hover, then goto" end
  if not (self.motion.frame_ok or self.bow_learned) then
    return false, "nav needs a confirmed bow axis: cruise forward until it is confirmed"
  end
  if s == nil then return false, "no telemetry" end
  if dock then
    self.nav:dock(list[1], s)
  else
    self.nav:start(list, s)
  end
  self:engage("NAV", s)
  if not dock then self:log("NAV LEG 1/" .. #list) end
  return true, "nav: leg 1/" .. #list
end

local NAV_LOCKED = { alt = true, alt_step = true, brg = true, brg_step = true, sync = true }

-- Docking moves: ship-relative, from the bearing being held.
local DOCK_MOVES = { fwd = true, aft = true, port = true, stbd = true, up = true, down = true, turn = true, here = true }
M.DOCK_USAGE = "dock fwd|aft|port|stbd|up|down <blocks> | dock turn <deg> | dock here"

-- One docking move { move =, n = }. Holds the new point in NAV by
-- translation alone. Returns ok, message.
function M:dock(v, s)
  if type(v) ~= "table" or not DOCK_MOVES[v.move] then return false, M.DOCK_USAGE end
  local m, n = v.move, v.n
  if m == "turn" then
    if not util.finite(n) or n == 0 or math.abs(n) > 180 then return false, "dock turn: -180 to 180 degrees" end
  elseif m ~= "here" then
    if not util.finite(n) or n <= 0 or n > 50 then return false, "dock moves: 1 to 50 blocks" end
  end
  local p
  if self.mode == "NAV" then
    p = self.nav:hold_point()
    if not p then return false, "NAV is flying: wait for ARRIVED or type hover" end
  elseif self.mode ~= "HOVER" then
    return false, "dock moves need HOVER or a NAV hold"
  end
  if s == nil then return false, "no telemetry" end
  if not p or m == "here" then
    p = { x = s.x, z = s.z, y = self.tgt.alt, brg = self.tgt.brg or util.round(s.hdg) % 360 }
  end
  p.y = p.y or self.tgt.alt or util.round(s.y)
  local b = math.rad(p.brg)
  local fx, fz, rx, rz = math.sin(b), -math.cos(b), math.cos(b), math.sin(b)
  if m == "fwd" then p.x, p.z = p.x + n * fx, p.z + n * fz
  elseif m == "aft" then p.x, p.z = p.x - n * fx, p.z - n * fz
  elseif m == "stbd" then p.x, p.z = p.x + n * rx, p.z + n * rz
  elseif m == "port" then p.x, p.z = p.x - n * rx, p.z - n * rz
  elseif m == "up" then p.y = p.y + n
  elseif m == "down" then p.y = p.y - n
  elseif m == "turn" then p.brg = (p.brg + n) % 360
  end
  p.y = util.clamp(p.y, -64, 2000)
  p.name = "dock"
  local ok, text = self:start_nav({ p }, s, true)
  if not ok then return ok, text end
  local label = m == "here" and "HERE" or (m:upper() .. " " .. util.fmt(n))
  self:log("DOCK " .. label)
  return true, string.format("dock %s: X %s Z %s Y %s BRG %s", label:lower(), util.fmt(p.x, 1), util.fmt(p.z, 1),
    util.fmt(p.y, 0), util.compass(p.brg))
end

-- Waypoint and route commands. Returns ok, message, or nil when c is not one.
function M:nav_command(c, v, s)
  local n = self.nav
  local nc = self.cfg.nav
  if c == "dock" then
    return self:dock(v, s)
  elseif c == "goto" then
    local leg, err = n:resolve(v)
    if not leg then return false, err end
    return self:start_nav({ leg }, s)
  elseif c == "route_add" then
    local leg, err = n:resolve(v)
    if not leg then return false, (err:gsub("^goto", "route add"):gsub("| goto", "| route add")) end
    if #n.route >= nc.max_legs then return false, "route is full (" .. nc.max_legs .. " legs)" end
    n.route[#n.route + 1] = leg
    return true, "route leg " .. #n.route
  elseif c == "route_clear" then
    n.route = {}
    return true, "route cleared"
  elseif c == "route_go" then
    if #n.route == 0 then return false, "route is empty" end
    local list = {}
    for i, leg in ipairs(n.route) do list[i] = { x = leg.x, z = leg.z, y = leg.y, brg = leg.brg, name = leg.name } end
    return self:start_nav(list, s)
  elseif c == "route_list" then
    if #n.route == 0 then return true, "route is empty" end
    local labels = {}
    for i, leg in ipairs(n.route) do labels[i] = nav.label(leg) end
    return true, "route: " .. table.concat(labels, " > ")
  elseif c == "wp_save" then
    if not nav.valid_name(v) then return false, nav.NAME_ERROR end
    if s == nil then return false, "no telemetry" end
    if n.points[v] == nil and n:count_points() >= nc.max_points then
      return false, "waypoint list is full (" .. nc.max_points .. ")"
    end
    n.points[v] = { x = util.round(s.x), z = util.round(s.z), y = util.round(s.y),
      brg = util.round(s.hdg) % 360, name = v }
    return true, "waypoint " .. v .. " saved"
  elseif c == "wp_del" then
    if n.points[v] == nil then return false, "no waypoint " .. tostring(v) end
    n.points[v] = nil
    return true, "waypoint " .. v .. " deleted"
  elseif c == "wp_list" then
    local names = n:names()
    if #names == 0 then return true, "no waypoints" end
    return true, "waypoints: " .. table.concat(names, ", ")
  end
  return nil
end

-- Handle one command { c = name, v = value }. Returns ok, message.
function M:command(msg, s)
  local c, v = msg.c, msg.v
  local ok, text = self:nav_command(c, v, s)
  if ok ~= nil then return ok, text end
  if self.mode == "NAV" and NAV_LOCKED[c] then return false, "NAV is flying: type hover to take over" end
  if c == "mode" then
    if not M.MODES[v] then return false, "unknown mode " .. tostring(v) end
    if s == nil and M.FLYING[v] then return false, "no telemetry" end
    if v == "NAV" and self.mode ~= "NAV" then return false, "nav needs a destination: goto or route go" end
    self:engage(v, s)
    return true, "mode " .. v
  elseif c == "alt" then
    if not util.finite(v) then return false, "altitude must be a number" end
    self.tgt.alt = util.clamp(v, -64, 2000)
    self:log("ALT " .. util.fmt(self.tgt.alt))
    return true, "altitude " .. util.fmt(self.tgt.alt)
  elseif c == "alt_step" then
    if not util.finite(v) then return false, "step must be a number" end
    local base = self.tgt.alt or (s and util.round(s.y)) or 0
    return self:command({ c = "alt", v = base + v }, s)
  elseif c == "brg" then
    if not util.finite(v) then return false, "bearing must be a number" end
    self.tgt.brg = util.wrap360(v)
    self:log("BRG " .. util.fmt(self.tgt.brg))
    return true, "bearing " .. util.fmt(self.tgt.brg)
  elseif c == "brg_step" then
    if not util.finite(v) then return false, "step must be a number" end
    local base = self.tgt.brg or (s and util.round(s.hdg)) or 0
    return self:command({ c = "brg", v = base + v }, s)
  elseif c == "spd" then
    if not util.finite(v) then return false, "speed must be a number" end
    if self.mode == "NAV" then
      self.nav.speed = util.clamp(math.abs(v), self.cfg.nav.min_speed, self.cfg.speed.max)
      self:log("NAV SPD " .. util.fmt(self.nav.speed))
      return true, "nav speed " .. util.fmt(self.nav.speed)
    end
    self.tgt.spd = util.clamp(v, -self.cfg.speed.max, self.cfg.speed.max)
    if self.mode == "CRUISE" and s then self.spd:set_target(self.tgt.spd, s.v_fwd) end
    self:log("SPD " .. util.fmt(self.tgt.spd))
    return true, "speed " .. util.fmt(self.tgt.spd)
  elseif c == "spd_step" then
    if not util.finite(v) then return false, "step must be a number" end
    local base = self.mode == "NAV" and self.nav.speed or (self.tgt.spd or 0)
    return self:command({ c = "spd", v = base + v }, s)
  elseif c == "sync" then
    if s == nil then return false, "no telemetry" end
    self.tgt.alt = util.round(s.y)
    self.tgt.brg = util.round(s.hdg) % 360
    self:log("SYNC")
    return true, "targets set to current altitude and heading"
  elseif c == "rcs_check" then
    if self.rcs_off then return false, "rcs is off: type 'rcs on' first" end
    if self.mode ~= "HOVER" or self.alt.grounded then
      return false, "rcs check runs in HOVER, in the air"
    end
    self.check = rcscheck.new(self.cfg)
    self.rcs_found = nil
    self:log("RCS CHECK START")
    return true, "rcs check: one corner at a time, about 45 s"
  elseif c == "rcs_off" then
    if self.check then
      self.check = nil
      self:log("RCS CHECK STOPPED")
    end
    if self.mode == "NAV" and s then
      self:engage("HOVER", s)
      self:log("NAV CANCELLED: RCS OFF")
    end
    self.rcs_off = true
    self:log("RCS OFF")
    return true, "rcs off: helm steers"
  elseif c == "rcs_on" then
    self.rcs_off = false
    self.hdg:reset()
    self:log("RCS ON")
    -- Hold the heading the helm left the ship on, not the old bearing.
    if s then self.tgt.brg = util.round(s.hdg) % 360 end
    return true, "rcs on: bearing " .. util.compass(self.tgt.brg)
  elseif c == "rcs_reset" then
    -- Forget the learned RCS turning and sideways strength: back to the
    -- first guesses, learned again in flight. The corner layout from an RCS
    -- check and the bow axis stay.
    self.hdg = heading.new(self.cfg, nil)
    local frame_ok = self.motion.frame_ok
    self.motion = motion.new(self.cfg, self.tel)
    self.motion.frame_ok = frame_ok
    self:log("RCS CAL RESET")
    return true, "rcs turning and sideways strength reset to the first guess"
  elseif c == "rcs_apply" then
    if not self.rcs_found then return false, "nothing to apply: run rcs check first" end
    self.rcs_map = self.rcs_found
    self.rcs_found = nil
    self:log("RCS LAYOUT SAVED")
    return true, "rcs layout saved; the flight computer restarts with it"
  elseif c == "recal" then
    -- Forget the hover calibration: back to the default guess, then learn
    -- again in flight. (Seeding from the lift RPM on screen would keep a bad
    -- calibration whenever that RPM is not really holding the hull up.)
    self.alt:reset_calibration()
    self:log("HOVER CAL RESET")
    return true, "hover calibration reset to " .. self.cfg.altitude.default_hover_rpm .. " RPM at sea level"
  end
  return false, "unknown command " .. tostring(c)
end

-- Collective lift RPM L spread over the four corners by the levelling. The
-- levelling reads pitch and roll along the bow axis, so it waits until the
-- pushers have confirmed (or corrected) that axis: with frame.forward wrong
-- it would tip the hull further instead of levelling it.
function M:put_lift(out, L, s, dt)
  local active = not self.alt.grounded and (self.motion.frame_ok or self.bow_learned)
  for id, rpm in pairs(self.level:mix(L, s, dt, active)) do out[id] = rpm end
end

-- One control step. Returns desired RPM per motor (nil = leave alone).
function M:step(s, now, dt, bank)
  local out = {}
  local cfg = self.cfg
  bank.exact = self.mode == "DEBUG"
  local thr_applied = bank:effective("thrust")
  local thr_cap = self.caps.thrust_port

  if self.mode == "KILL" then
    for _, id in ipairs(actuators.ORDER) do out[id] = 0 end
    return out
  end
  if self.mode == "DEBUG" then
    -- The bank multiplies by sign on write; pre-multiply so the block gets +rpm.
    for _, id in ipairs(actuators.ORDER) do out[id] = cfg.debug_rpm * (cfg.motors[id].sign or 1) end
    return out
  end

  local flying = M.FLYING[self.mode]
  local want_up = flying and self.tgt.alt ~= nil and self.tgt.alt > s.y + cfg.altitude.hold_band
  -- Learning uses the force the props are really making (their modelled
  -- spin, which lags the controller by up to ~1.6 s), not the commanded RPM.
  local lift_prop = bank:effective("lift", now)
  local thr_prop = bank:effective("thrust", now)
  local rcs_prop = {}
  for _, id in ipairs(RCS) do rcs_prop[id] = bank:prop(id, now) end
  local u_now, sw_now = heading.applied(rcs_prop, self.caps)
  local thr_f = util.ssq(thr_prop) / (thr_cap * thr_cap)
  -- The hover is learned only while the autopilot flies the hull. Parked
  -- with the lift turning (STBY after DEBUG leaves 15 RPM on it), a hull
  -- resting on its moorings would teach that 15 RPM hovers.
  if flying then
    self.alt:observe(s, lift_prop, now, want_up)
  end
  self.spd:observe(s, thr_f, now)
  if self.check then
    -- Single corners at full are not normal flight: learn nothing from them.
    self.hdg.win, self.motion.win = nil, nil
  else
    self.hdg:observe(s, u_now, now)
    self.motion:observe(s, thr_f, sw_now, now)
  end

  -- The rear thrusters showed the bow is on another axis than configured:
  -- switch to it, keep pointing where the ship points now, relearn speed.
  local bow = self.motion.bow
  if bow and util.dot(bow, self.tel.forward) < 0.9 then
    local delta = util.wrap180(motion.plane_angle(self.tel, bow) - motion.plane_angle(self.tel, self.tel.forward))
    self.tel.set_forward(bow)
    if self.tgt.brg then self.tgt.brg = (self.tgt.brg + delta) % 360 end
    self.bow_learned, self.bow_changed_at, self.motion.frame_ok = true, now, true
    self:log("BOW AXIS CORRECTED " .. util.fmt(delta) .. " DEG")
    s = self.tel.read()
    self.spd:forget(s.v_fwd)
    self.hdg:reset()
  end

  if not flying then
    out.thrust_port, out.thrust_stbd = 0, 0
    for _, id in ipairs(RCS) do out[id] = 0 end
    return out
  end

  -- RCS check: one corner at a time; altitude held, everything else rests.
  if self.check then
    local log = function(text) self:log(text) end
    local rpm = self.check:step(s, now, log)
    if rpm then
      self:put_lift(out, self.alt:command(s, self.tgt.alt, dt, self.caps.lift_bow_port), s, dt)
      out.thrust_port, out.thrust_stbd = 0, 0
      for _, id in ipairs(RCS) do out[id] = rpm[id] end
      return out
    end
    self:finish_check()
  end

  if self.mode == "NAV" then
    local cmd = self.nav:step(s, now)
    self.tgt.alt, self.tgt.brg, self.tgt.spd = cmd.alt, cmd.brg, cmd.spd
    -- Re-ramp only when the target changes: set_target plans the ramp from
    -- the reference's gap to it.
    local sent = self.nav_sent
    if not sent or sent.spd ~= cmd.spd or sent.rate ~= cmd.rate then
      self.spd:set_target(cmd.spd, s.v_fwd, cmd.rate)
      self.nav_sent = { spd = cmd.spd, rate = cmd.rate }
    end
    self.sway_target = cmd.side
  end
  self:put_lift(out, self.alt:command(s, self.tgt.alt, dt, self.caps.lift_bow_port), s, dt)
  local T = 0
  if self.rcs_off and self.spd.target == 0 then
    -- At zero target the pushers are fore/aft RCS, not cruise propulsion.
    -- Release them to the helm too; do not integrate against manual drift.
    self.pusher_released = true
    self.spd.phase, self.spd.saturated = "OFF", 0
  else
    if self.pusher_released then
      self.spd:reset(s.v_fwd)
      self.pusher_released = false
    end
    local pending = util.ssq(thr_applied) / (thr_cap * thr_cap) - thr_f
    T = self.spd:command(s, dt, thr_cap, thr_applied, pending)
  end
  out.thrust_port, out.thrust_stbd = T, T
  local station = self.mode == "HOVER" or (self.mode == "NAV" and self.nav.phase ~= "TRANSIT")
  local deadzone = station and cfg.heading.hover_deadzone or cfg.heading.cruise_deadzone
  -- Until the frame is confirmed (or learned), a wrong axis would make the
  -- sideways brake push the wrong way: keep it gentle.
  local auth = self.motion:sway_authority()
  local sway = {
    drift = s.v_side, target = self.sway_target or 0, auth = auth, coming = auth * sw_now * cfg.heading.sway_lag,
    limit = (self.motion.frame_ok or self.bow_learned) and 1 or cfg.heading.probe_limit,
  }
  if self.rcs_off then
    -- The Eureka helm steers: the RCS rests and the heading loop starts
    -- afresh when it is handed back.
    for _, id in ipairs(RCS) do out[id] = 0 end
    self.hdg:reset()
    self.rcs_full_since = nil
  else
    local rcs_set = {}
    for _, id in ipairs(RCS) do rcs_set[id] = bank:applied(id) end
    local u_set = heading.applied(rcs_set, self.caps)
    local u, sw = self.hdg:command(s, self.tgt.brg, dt, deadzone, sway, u_set - u_now)
    -- Pulling at full and still off the bearing: the RCS can't hold this
    -- (e.g. thrust line too far off centre for the RCS cap).
    if math.abs(u) >= 0.99 and math.abs(self.hdg.err) > deadzone then
      self.rcs_full_since = self.rcs_full_since or now
    else
      self.rcs_full_since = nil
    end
    local rcs = heading.mix(u, sw, self.caps, cfg.actuator.rcs_min_rpm)
    for _, id in ipairs(RCS) do out[id] = rcs[id] end
  end

  if self.spd.saturated ~= 0 and self.spd.phase ~= "HOLD" then
    self.accel_limited_since = self.accel_limited_since or now
  else
    self.accel_limited_since = nil
  end
  return out
end

-- Current warnings for the displays.
function M:alerts(s, now)
  local list = {}
  if self.mode == "KILL" then list[#list + 1] = "KILL: ALL THRUST CUT" end
  if self.rcs_off then list[#list + 1] = "RCS OFF: HELM STEERS" end
  if self.mode == "DEBUG" then
    list[#list + 1] = "DEBUG: ALL PROPS AT +" .. self.cfg.debug_rpm .. " RPM, LIFT TOO"
  end
  local flying = M.FLYING[self.mode]
  if self.rcs_full_since and now - self.rcs_full_since > 3 then
    list[#list + 1] = "RCS AT FULL: HEADING NOT HELD"
    if self.hdg:authority() <= self.cfg.heading.min_authority * 1.5 then
      list[#list + 1] = "TURN COMMANDS DO NOT TURN THE SHIP: RUN 'rcs check'"
    end
  end
  if self.check then
    list[#list + 1] = "RCS CHECK: TESTING " .. (self.check:testing() or "..."):upper()
  end
  if self.rcs_found then list[#list + 1] = "RCS LAYOUT DIFFERS FROM CONFIG: TYPE 'rcs apply'" end
  if self.bow_changed_at and now - self.bow_changed_at < 30 then
    list[#list + 1] = "BOW AXIS CORRECTED: HEADING NOW TRUE"
  end
  if flying and self.hdg.sway_active and not (self.motion.frame_ok or self.bow_learned) then
    list[#list + 1] = "BOW AXIS NOT CONFIRMED YET: SIDEWAYS BRAKE GENTLE"
  end
  if flying and self.hdg.sway_failed then
    list[#list + 1] = "SIDEWAYS BRAKE STOPPED: IT MADE THE DRIFT WORSE (RUN 'rcs check')"
  end
  if s and math.abs(s.yaw_rate) > 3 * self.cfg.heading.max_rate then
    list[#list + 1] = "SPINNING " .. util.fmt(s.yaw_rate, 0) .. " DEG/S"
  end
  if self.alt.saturated and flying then
    list[#list + 1] = "ELEVATION AT RPM CAP"
  end
  if self.spd.pitch_hold then list[#list + 1] = "PITCH LIMIT: THRUST HELD" end
  if self.accel_limited_since and now - self.accel_limited_since > 2 then
    list[#list + 1] = "PUSHERS AT CAP"
  end
  if s and s.gs > self.cfg.speed.max + 1 then list[#list + 1] = "OVERSPEED" end
  return list
end

function M:saved()
  local h = self.hdg:saved()
  local f = self.tel.forward
  return {
    k = self.alt.k, A = self.spd.A, Dn = self.spd.Dn, yaw_b = h.yaw_b,
    rcs_cap = self.caps.bow_port,
    -- A confirmed config axis is kept too, so the levelling runs from the
    -- start of the next flight.
    bow = (self.bow_learned or self.motion.frame_ok) and { x = f.x, y = f.y, z = f.z } or nil,
    rcs_map = self.rcs_map,
  }
end

-- An RCS check has finished: compare what it found with the motors in use.
function M:finish_check()
  local chk = self.check
  self.check = nil
  self.hdg:reset()
  local layout, why = chk:layout()
  if not layout then
    self:log("RCS CHECK UNCLEAR: " .. why)
    return
  end
  local same = true
  local map = {}
  for corner, id in pairs(layout) do
    if corner ~= id then same = false end
    map[corner] = self.cfg.motors[id].name
  end
  if same then
    self:log("RCS LAYOUT MATCHES CONFIG")
  else
    self.rcs_found = map
    for _, corner in ipairs(RCS) do
      if layout[corner] ~= corner then
        self:log(corner:upper() .. " IS " .. self.cfg.motors[layout[corner]].label:match("^(%S+)"))
      end
    end
    self:log("RCS LAYOUT DIFFERS: TYPE 'rcs apply'")
  end
end

return M
