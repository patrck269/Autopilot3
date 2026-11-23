-- Closed-loop flight checks against tests/plant.lua. Run from the repo root:
--   lua tests/test_flight.lua
package.path = "./?.lua;" .. package.path
local plant = require("tests.plant")
local util = require("ap3.util")

-- Station keeping holds inside deliberate bands (fewer controller writes):
-- altitude is held closed-loop within 1 block, heading within the mode's
-- deadzone plus about half a unit for actuator lag. Clockwork props take
-- ~3.1 s to spin from 0 to 2000 RPM (world.lua models that), which costs a
-- little more at speed.
local CFG = dofile("ap3/config.lua")
local ALT_TOL = 1.0
local HDG_HOVER = CFG.heading.hover_deadzone + 0.5
local HDG_CRUISE = 4

local failures = 0
local function check(cond, label, detail)
  if cond then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("  FAIL  " .. label .. (detail and ("  (" .. detail .. ")") or ""))
  end
end

local function hover_rpm_true(sim, y)
  return sim.p.hover_rpm_sea * math.sqrt(plant.rho(62) / plant.rho(y))
end

-- Track altitude behaviour from a moment on.
local function watch()
  local m = { max_y = -1e9, min_y = 1e9, max_vy = 0, reached = nil }
  m.hook = function(sim, s)
    if s.y > m.max_y then m.max_y = s.y end
    if s.y < m.min_y then m.min_y = s.y end
    if math.abs(s.vy) > m.max_vy then m.max_vy = math.abs(s.vy) end
  end
  return m
end

print("1. Ground start, no calibration, climb to 150 and hold")
do
  -- Real hover is 900 RPM at sea level; the untrained guess is 430.
  local sim = plant.new({ hover_rpm_sea = 900 })
  sim.cmd("alt", 150)
  sim.cmd("mode", "HOVER")
  local reached
  sim.run(120, function(s2, s)
    if not reached and math.abs(s.y - 150) < 1 then reached = s2.w.t end
  end)
  check(reached ~= nil and reached < 80, "reaches 150 +-1", "t=" .. tostring(reached))
  local m = watch()
  sim.run(60, m.hook)
  check(m.max_y - 150 < ALT_TOL and 150 - m.min_y < ALT_TOL, "holds 150 within " .. ALT_TOL .. " for 60 s",
    string.format("min %.2f max %.2f", m.min_y, m.max_y))
  local hov = hover_rpm_true(sim, 150)
  local learned = sim.ap.alt:hover_rpm(plant.rho(150))
  check(math.abs(learned - hov) / hov < 0.03, "learned hover RPM within 3%",
    string.format("learned %.1f true %.1f", learned, hov))
  print(string.format("     liftoff->150 in %.1f s, lift %.0f RPM, writes %d", reached or -1, sim.lift_cmd(), sim.w.writes))

  print("2. Same flight: climb to 400 (thinner air) then descend to 90")
  sim.cmd("alt", 400)
  local m2 = watch()
  local t0 = sim.w.t
  local r400
  sim.run(150, function(s2, s)
    m2.hook(s2, s)
    if not r400 and math.abs(s.y - 400) < 1 then r400 = s2.w.t - t0 end
  end)
  check(r400 ~= nil, "reaches 400", "t=" .. tostring(r400))
  check(m2.max_y < 403, "overshoot under 3 blocks", string.format("max %.2f", m2.max_y))
  check(math.abs(sim.w.y - 400) < 0.8, "holds 400", string.format("y %.2f", sim.w.y))
  local hov4 = hover_rpm_true(sim, 400)
  check(math.abs(sim.lift_cmd() - hov4) / hov4 < 0.04, "lift RPM at 400 near true hover",
    string.format("cmd %.0f true %.1f", sim.lift_cmd(), hov4))
  print(string.format("     150->400 in %.1f s, max climb %.2f m/s", r400 or -1, m2.max_vy))

  sim.cmd("alt", 90)
  local m3 = watch()
  sim.run(150, m3.hook)
  check(m3.min_y > 87, "descent undershoot under 3 blocks", string.format("min %.2f", m3.min_y))
  check(math.abs(sim.w.y - 90) < 0.8, "holds 90", string.format("y %.2f", sim.w.y))
end

print("3. Heavy hull (hover 2200 RPM) from the ground")
do
  local sim = plant.new({ hover_rpm_sea = 2200 })
  sim.cmd("alt", 120)
  sim.cmd("mode", "HOVER")
  sim.run(150)
  check(math.abs(sim.w.y - 120) < 1, "reaches and holds 120", string.format("y %.2f", sim.w.y))
end

print("4. Light hull (hover 300 RPM), calibration guess too high")
do
  local sim = plant.new({ hover_rpm_sea = 300 })
  sim.cmd("alt", 100)
  sim.cmd("mode", "HOVER")
  local m = watch()
  sim.run(120, m.hook)
  check(math.abs(sim.w.y - 100) < 1, "reaches and holds 100", string.format("y %.2f", sim.w.y))
  check(m.max_y < 106, "overshoot under 6 blocks on the first climb", string.format("max %.2f", m.max_y))
end

print("5. Cruise: 0 -> 30 m/s within 15 s, hold bearing and altitude")
do
  -- Off-centre thrust line: at full pusher thrust it needs about a quarter of
  -- what one RCS pair can give at 2000 RPM.
  local sim = plant.new({ hover_rpm_sea = 900, y = 200, lift = 900, misalign = 0.01, psi = 10,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("brg", 90)
  sim.cmd("mode", "HOVER")
  sim.run(40)
  check(math.abs(util.wrap180(sim.s.hdg - 90)) < HDG_HOVER, "hover turns to bearing 90", string.format("hdg %.2f", sim.s.hdg))
  sim.cmd("spd", 30)
  sim.cmd("mode", "CRUISE")
  local t0 = sim.w.t
  local reach
  local max_hdg_err, max_alt_err, max_v = 0, 0, 0
  sim.run(40, function(s2, s)
    if not reach and math.abs(s.v_fwd - 30) < 1 then reach = s2.w.t - t0 end
    if s2.w.t - t0 > 3 then
      max_hdg_err = math.max(max_hdg_err, math.abs(util.wrap180(s.hdg - 90)))
    end
    max_alt_err = math.max(max_alt_err, math.abs(s.y - 200))
    max_v = math.max(max_v, s.v_fwd)
  end)
  check(reach ~= nil and reach <= 15, "30 m/s (+-1) within 15 s", "t=" .. tostring(reach))
  check(max_v < 31.5, "speed overshoot under 1.5 m/s", string.format("max %.2f", max_v))
  check(max_hdg_err < HDG_CRUISE, "heading within " .. HDG_CRUISE .. " deg at speed with thrust misalignment",
    string.format("%.2f", max_hdg_err))
  check(max_alt_err < 2, "altitude within 2 blocks", string.format("%.2f", max_alt_err))

  print("6. Cap at 35 m/s")
  local ok = sim.ap:command({ c = "spd", v = 50 }, sim.s)
  check(ok and sim.ap.tgt.spd == 35, "target 50 clamps to 35", tostring(sim.ap.tgt.spd))
  local max_v2 = 0
  sim.run(40, function(_, s) max_v2 = math.max(max_v2, s.v_fwd) end)
  check(max_v2 <= 35.5, "speed never above 35.5", string.format("%.2f", max_v2))
  check(math.abs(sim.s.v_fwd - 35) < 1, "settles at 35", string.format("%.2f", sim.s.v_fwd))

  print("7. Slow to 0 with reverse thrust")
  sim.cmd("spd", 0)
  local reverse, t0b, stopped = false, sim.w.t, nil
  sim.run(40, function(s2, s)
    if s2.w.cmd.thrust_port < 0 then reverse = true end
    if not stopped and math.abs(s.v_fwd) < 0.5 then stopped = s2.w.t - t0b end
  end)
  check(reverse, "pushers ran in reverse")
  check(stopped ~= nil and stopped <= 15, "stopped (<0.5 m/s) within 15 s", "t=" .. tostring(stopped))
end

print("8. Nose dips under acceleration: thrust held back")
do
  -- Unprotected, the most thrust the speed loop asks for (max_accel beyond
  -- drag) would pitch the nose about 10 deg down; cruise drag alone about 2.
  local sim = plant.new({ hover_rpm_sea = 900, y = 200, lift = 900, dip = 0.8,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } },
    cfg = function(cfg) cfg.level.kp, cfg.level.kd, cfg.level.ki = 0, 0, 0 end })
  sim.cmd("alt", 200)
  sim.cmd("spd", 30)
  sim.cmd("mode", "CRUISE")
  local min_pitch, held, reach = 0, false, nil
  sim.run(60, function(s2, s)
    min_pitch = math.min(min_pitch, s.pitch)
    if s2.ap.spd.pitch_hold then held = true end
    if not reach and math.abs(s.v_fwd - 30) < 1 then reach = s2.w.t end
  end)
  check(held, "pitch protection engaged")
  local limit = sim.cfg.speed.pitch_limit
  check(min_pitch > -(limit + 2), "nose dip kept within limit + 2 deg", string.format("%.2f", min_pitch))
  check(reach ~= nil, "still reaches 30 m/s", "t=" .. tostring(reach))
  print(string.format("     reached 30 m/s at %.1f s with the nose limited", reach or -1))
end

print("9. KILL zeroes every motor at once")
do
  local sim = plant.new({ hover_rpm_sea = 900, y = 200, lift = 900,
    saved = { k = 10 / (plant.rho(62) * 900 * 900) } })
  sim.cmd("spd", 20)
  sim.cmd("mode", "CRUISE")
  sim.run(10)
  sim.cmd("mode", "KILL")
  sim.run(0.4)
  local zero = 0
  for _, v in pairs(sim.w.cmd) do if v == 0 then zero = zero + 1 end end
  check(zero == 10, "all ten motors at 0 within 0.4 s", zero .. " at 0")
end

print("10. Noisy velocity readings (+-0.15 m/s): calibrate and hold")
do
  math.randomseed(7)
  local sim = plant.new({ hover_rpm_sea = 1200, noise = 0.15 })
  sim.cmd("alt", 140)
  sim.cmd("mode", "HOVER")
  sim.run(100)
  local m = watch()
  sim.run(60, m.hook)
  check(m.max_y - 140 < ALT_TOL and 140 - m.min_y < ALT_TOL, "holds 140 within " .. ALT_TOL,
    string.format("min %.2f max %.2f", m.min_y, m.max_y))
end

-- Hover with the bearing 40 deg off. Returns max |yaw rate|, final heading
-- error, and the largest heading error over the last 20 s.
local function turn_in_hover(opts)
  opts.y = 200
  opts.lift = 900
  opts.psi = 0
  opts.saved = { k = 10 / (plant.rho(62) * 900 * 900) }
  local sim = plant.new(opts)
  sim.cmd("alt", 200)
  sim.cmd("brg", 40)
  sim.cmd("mode", "HOVER")
  local max_rate, late_err = 0, 0
  sim.run(opts.seconds or 90, function(s2, s)
    max_rate = math.max(max_rate, math.abs(s.yaw_rate))
    if s2.w.t > (opts.seconds or 90) - 20 then
      late_err = math.max(late_err, math.abs(util.wrap180(s.hdg - 40)))
    end
  end)
  return sim, max_rate, math.abs(util.wrap180(sim.s.hdg - 40)), late_err
end

-- Longest run of ticks with an RCS corner pulling without its diagonal
-- partner (with the helm's stabilisation that strafes the hull instead of
-- turning it). Pair writes go back to back, so at most one tick.
local function lonely_run(sim)
  return sim.w.lonely_max
end

print("11. Turn 40 deg in hover: settles, pairs run together")
do
  local sim, max_rate, err, late = turn_in_hover({})
  check(max_rate < 10, "yaw rate stays under 10 deg/s", string.format("max %.1f", max_rate))
  check(late < 1, "bearing stays within 1 deg after the turn (no +-2 deg bounce)",
    string.format("err %.2f, late max %.2f", err, late))
  check(lonely_run(sim) <= 1, "diagonal pairs run together", lonely_run(sim) .. " ticks alone at most")
end

print("12. Very strong RCS: no limit cycle")
do
  local sim, max_rate, err, late = turn_in_hover({ yaw_accel = 60 })
  check(max_rate < 10, "yaw rate stays under 10 deg/s", string.format("max %.1f", max_rate))
  check(late < HDG_HOVER, "settles on the bearing", string.format("err %.2f, late max %.2f", err, late))
  check(lonely_run(sim) <= 1, "diagonal pairs run together", lonely_run(sim) .. " ticks alone at most")
end

print("13. Weak RCS: still turns")
do
  local sim, max_rate, err, late = turn_in_hover({ yaw_accel = 1.0, seconds = 150 })
  check(late < HDG_HOVER, "settles on the bearing", string.format("err %.2f, late max %.2f", err, late))
  check(lonely_run(sim) <= 1, "diagonal pairs run together", lonely_run(sim) .. " ticks alone at most")
end

local RCS_CAP = CFG.motors.bow_port.cap
print("14. RCS writes never exceed the " .. RCS_CAP .. " RPM cap, even saturated")
do
  local migrated = plant.new({ saved = { yaw_b = 0.5, rcs_cap = 1000 } })
  local want = 0.5 * (RCS_CAP / 1000) ^ 2
  check(math.abs(migrated.ap.hdg:authority() - want) < 1e-9,
    "saved yaw authority scales with the RPM cap", string.format("%.2f", migrated.ap.hdg:authority()))
  local weak_saved = plant.new({ saved = { yaw_b = 0.15, rcs_cap = 2000 } })
  local weak_want = 0.15 * (RCS_CAP / 2000) ^ 2
  check(math.abs(weak_saved.ap.hdg:authority() - weak_want) < 1e-9,
    "old weak calibration is validated after cap rescaling", tostring(weak_saved.ap.hdg:authority()))
  -- A hull too weak for the turn: the RCS pulls at full.
  local sim = plant.new({ y = 200, lift = 900, psi = 0, yaw_accel = 0.02, yaw_damp = 2,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), yaw_b = 6, rcs_cap = RCS_CAP } })
  sim.cmd("alt", 200)
  sim.cmd("brg", 170)
  sim.cmd("mode", "HOVER")
  local top = 0
  sim.run(40, function(s2)
    for _, id in ipairs({ "bow_port", "bow_stbd", "stern_port", "stern_stbd" }) do
      top = math.max(top, math.abs(s2.w.cmd[id]))
    end
  end)
  check(top <= RCS_CAP and top >= 0.99 * RCS_CAP, "RCS reaches but does not pass " .. RCS_CAP .. " RPM", "max " .. top)
end

print("15. DEBUG: every motor at +15 RPM on the block, calibration untouched")
do
  local sim = plant.new({ y = 200, lift = 900,
    saved = { k = 10 / (plant.rho(62) * 900 * 900) },
    cfg = function(cfg) cfg.motors.bow_port.sign = -1 end })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(5)
  local k = sim.ap.alt.k
  sim.cmd("mode", "DEBUG")
  sim.run(6) -- the lift steps down to 15 RPM through the slew limit
  local n = 0
  for id, v in pairs(sim.w.cmd) do
    if v == 15 then n = n + 1 else print("     " .. id .. " = " .. v) end
  end
  check(n == 10, "all ten motors at +15 (bow_port has sign -1 in config)")
  sim.run(5) -- the hull drops on 15 RPM lift
  check(sim.ap.alt.k == k, "hover calibration unchanged by the drop")
  sim.cmd("mode", "HOVER")
  sim.run(40)
  check(math.abs(sim.w.y - 200) < 1.5, "HOVER afterwards climbs back to 200", string.format("y %.2f", sim.w.y))
end

print("19. Already drifting sideways when HOVER engages: drift cancelled")
do
  local case = { "starting drift" }
  -- 3 m/s to starboard, hardly any side drag (a VS hull keeps sliding).
  local opts = { y = 150, lift = 958, psi = 30, v_side = 3, side_drag = 0.02,
    saved = { k = 10 / (plant.rho(62) * 900 * 900) } }
  local sim = plant.new(opts)
  sim.cmd("alt", 150)
  sim.cmd("brg", 30)
  sim.cmd("mode", "HOVER")
  local stopped, worst_hdg = nil, 0
  sim.run(90, function(s2, s)
    if not stopped and math.abs(s.v_side) < 0.3 then stopped = s2.w.t end
    worst_hdg = math.max(worst_hdg, math.abs(util.wrap180(s.hdg - 30)))
  end)
  check(stopped ~= nil, case[1] .. ": drift brought under 0.3 m/s", "t=" .. tostring(stopped))
  check(math.abs(sim.s.v_side) < 0.5, case[1] .. ": and kept there", string.format("%.2f m/s", sim.s.v_side))
  check(worst_hdg < 6, case[1] .. ": heading held while braking", string.format("worst %.2f deg", worst_hdg))
  print(string.format("     drift stopped after %.1f s, sideways strength %.3f m/s2", stopped or -1,
    sim.ap.motion:sway_authority()))
end

print("20. frame.forward set wrong: bow axis learned, drift cancelled, cruise works")
for _, case in ipairs({ { "90 deg off", { x = 0, y = 0, z = -1 } }, { "180 deg off", { x = -1, y = 0, z = 0 } } }) do
  -- The hull's real bow is +X; the config says otherwise. Drifting 3 m/s at start.
  local sim = plant.new({ y = 150, lift = 958, psi = 30, v_side = 3, side_drag = 0.02,
    saved = { k = 10 / (plant.rho(62) * 900 * 900) },
    cfg = function(cfg) cfg.frame.forward = case[2] end })
  sim.cmd("alt", 150)
  sim.cmd("mode", "HOVER")
  local switches, last = 0, 0
  local function true_side()
    local a = math.rad(sim.w.psi)
    return sim.w.vx * math.cos(a) + sim.w.vz * math.sin(a)
  end
  local worst = 0
  sim.run(90, function(s2)
    local stb = s2.w.cmd.bow_stbd > 0 and s2.w.cmd.stern_stbd > 0
    local prt = s2.w.cmd.bow_port > 0 and s2.w.cmd.stern_port > 0
    local side = stb and 1 or (prt and -1 or 0)
    if side ~= 0 and side ~= last then switches = switches + 1; last = side end
    worst = math.max(worst, math.abs(true_side()))
  end)
  -- 90 deg off: the drift shows up as fore/aft, the pushers brake it
  -- and reveal the bow. 180 deg off: a sideways drift can't reveal it and
  -- the brake pushes the wrong way until a cruise shows the bow (the guard
  -- that used to stop it also stopped the brake for real slides in game).
  if case[1] == "90 deg off" then
    check(worst < 4, case[1] .. ": the drift is never made much worse", string.format("worst %.2f m/s (started 3)", worst))
  end
  check(switches <= 4, case[1] .. ": brake does not flap port/starboard", switches .. " side changes")
  -- The bow is learned from the pushers' push, so it may need a cruise.
  local brg = util.round(sim.s.hdg) % 360
  sim.cmd("brg", brg)
  sim.cmd("spd", 15)
  sim.cmd("mode", "CRUISE")
  local top = 0
  sim.run(40, function(s2) top = math.max(top, math.sqrt(s2.w.vx ^ 2 + s2.w.vz ^ 2)) end)
  check(util.dot(sim.tel.forward, { x = 1, y = 0, z = 0 }) > 0.99, case[1] .. ": bow axis learned as +X",
    util.axis_name(sim.tel.forward))
  check(math.abs(util.wrap180(sim.s.hdg - sim.w.psi)) < 1, case[1] .. ": heading reads true",
    string.format("reads %.1f, true %.1f", sim.s.hdg, sim.w.psi))
  local a = math.rad(sim.w.psi)
  local true_fwd = sim.w.vx * math.sin(a) - sim.w.vz * math.cos(a)
  check(math.abs(true_fwd - 15) < 1.5, case[1] .. ": cruises at 15 m/s along the real bow", string.format("%.2f m/s", true_fwd))
  check(top < 18, case[1] .. ": no runaway before the axis is learned", string.format("top %.1f m/s", top))
  -- Back to a hover with the right axis: any drift is braked out.
  sim.cmd("mode", "HOVER")
  sim.run(90)
  check(math.abs(true_side()) < 0.5, case[1] .. ": sideways drift cancelled once the axis is known",
    string.format("%.2f m/s", true_side()))
end

print("21. Corner labels wrong (stern pair swapped): RCS check finds it, apply fixes the hover")
do
  local swapped = { stern_port = "stern_stbd", stern_stbd = "stern_port" }
  local base = { y = 150, lift = 958, psi = 30, saved = { k = 10 / (plant.rho(62) * 900 * 900) } }
  local function hull(at, saved)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    o.at, o.saved = at, saved or base.saved
    return plant.new(o)
  end
  local function hover_with_kick(sim)
    sim.cmd("alt", 150)
    sim.cmd("brg", 30)
    sim.cmd("mode", "HOVER")
    sim.w.r = -1.5 -- a small yaw kick as it lifts
    local late = 0
    sim.run(90, function(s2, s)
      if s2.w.t > 70 then late = math.max(late, math.abs(util.wrap180(s2.w.psi - 30))) end
    end)
    return late
  end
  local function events(sim) return table.concat(sim.ap.events, " | ") end

  local bad = hull(swapped)
  local late = hover_with_kick(bad)
  check(late > HDG_HOVER, "with the labels wrong the heading is not held (the in-game symptom)",
    string.format("off %.1f deg, learned turn %.3f", late, bad.ap.hdg:authority()))

  local sim = hull(swapped)
  sim.cmd("alt", 150)
  sim.cmd("mode", "HOVER")
  sim.run(5)
  sim.cmd("rcs_check")
  sim.run(60)
  check(sim.ap.check == nil, "check finishes", events(sim))
  local found = sim.ap.rcs_found
  check(found ~= nil and found.stern_stbd == "electric_motor_4"
    and found.stern_port == "electric_motor_0"
    and found.bow_port == "electric_motor_6" and found.bow_stbd == "electric_motor_1",
    "finds R4 at stern starboard and R0 at stern port", events(sim))
  check(math.abs(sim.w.y - 150) < 2, "altitude held during the check", string.format("y %.2f", sim.w.y))
  sim.cmd("rcs_apply")
  local saved = sim.ap:saved()
  check(saved.rcs_map ~= nil, "layout is saved with the calibration")

  local fixed = hull(swapped, saved)
  check(fixed.cfg.motors.stern_stbd.label == "R4 STRN STBD", "restart uses the saved layout",
    fixed.cfg.motors.stern_stbd.label)
  late = hover_with_kick(fixed)
  check(late < HDG_HOVER, "after apply the heading is held", string.format("off %.1f deg, learned turn %.3f", late, fixed.ap.hdg:authority()))

  local good = hull(nil)
  good.cmd("alt", 150)
  good.cmd("mode", "HOVER")
  good.run(5)
  good.cmd("rcs_check")
  local good_check = good.ap.check
  good.run(60)
  local matching = good_check:layout()
  local matches = matching ~= nil
  for _, id in ipairs({ "bow_port", "bow_stbd", "stern_port", "stern_stbd" }) do
    matches = matches and matching[id] == id
  end
  check(matches and good.ap.rcs_found == nil, "a correctly labelled hull needs no remap", events(good))
end

print("23. Saved turning strength from noise: a hover turn still uses the full RCS")
do
  -- The calibration the in-game flight computer saved: 1378 deg/s^2 held
  -- every turn command near 110 RPM, too weak to turn the hull or relearn.
  local sim = plant.new({ y = 150, lift = 958, psi = 0,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), yaw_b = 1378.0205797682015, rcs_cap = 2000,
      bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 150)
  sim.cmd("brg", 0)
  sim.cmd("mode", "HOVER")
  sim.run(20)
  sim.cmd("brg", 40)
  local top = 0
  sim.run(60, function(s2)
    for _, id in ipairs({ "bow_port", "bow_stbd", "stern_port", "stern_stbd" }) do
      top = math.max(top, s2.w.cmd[id] or 0)
    end
  end)
  local err = math.abs(util.wrap180(sim.w.psi - 40))
  check(top > 1000, "the 40 deg turn drives the RCS past 1000 RPM", "max " .. top .. " RPM")
  check(err < HDG_HOVER, "the turn completes within 60 s", string.format("off %.1f deg", err))
end

print("24. Off-centre load: the lift corners level the hull")
do
  -- Nose-up and port-down load: unlevelled, the hull's own stability alone
  -- would sit at about 3.75 deg pitch and -3.75 deg roll. The bow axis is
  -- confirmed (saved), so the levelling runs from the start.
  local sim = plant.new({ y = 150, lift = 900, psi = 0, pitch_load = 1.5, roll_load = -1.5,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 150)
  sim.cmd("brg", 0)
  sim.cmd("mode", "HOVER")
  local m = watch()
  sim.run(60, m.hook)
  check(math.abs(sim.s.pitch) < 1 and math.abs(sim.s.roll) < 1, "pitch and roll within 1 deg after 60 s",
    string.format("pitch %.2f roll %.2f, trim P %.3f R %.3f", sim.s.pitch, sim.s.roll,
      sim.ap.level.trim_pitch, sim.ap.level.trim_roll))
  check(m.max_y - 150 < ALT_TOL and 150 - m.min_y < ALT_TOL, "altitude held within " .. ALT_TOL,
    string.format("min %.2f max %.2f", m.min_y, m.max_y))
end

print("25. Pushers stay paired")
do
  local sim = plant.new({ y = 200, lift = 900, psi = 0,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("brg", 0)
  sim.cmd("mode", "HOVER")
  sim.run(5)
  sim.cmd("spd", 20)
  sim.cmd("mode", "CRUISE")
  sim.w.pusher_split_max = 0
  sim.run(40)
  check(math.abs(sim.s.v_fwd - 20) < 1, "cruises at 20 m/s", string.format("%.2f m/s", sim.s.v_fwd))
  check(sim.w.pusher_split_max <= 1, "the two pushers never differ for more than one tick",
    sim.w.pusher_split_max .. " ticks")
end

print("26. Parked on DEBUG's 15 RPM: the hover calibration is not taught that 15 RPM hovers")
do
  -- Autopilot 2.0 on another ship learned a 15 RPM hover this way: STBY after
  -- DEBUG leaves 15 RPM on the lift, and the hull jitters on its moorings.
  math.randomseed(11)
  local sim = plant.new({ hover_rpm_sea = 430, noise = 0.3, lift = 15 })
  local before = sim.ap.alt:hover_rpm(plant.rho(62))
  sim.run(60)
  local after = sim.ap.alt:hover_rpm(plant.rho(62))
  check(math.abs(after - before) < 1, "STBY with the lift turning learns nothing",
    string.format("hover %.0f -> %.0f RPM", before, after))
  local bad = plant.new({ saved = { k = 10 / (plant.rho(62) * 15 * 15) } })
  check(math.abs(bad.ap.alt:hover_rpm(plant.rho(62)) - CFG.altitude.default_hover_rpm) < 1,
    "a saved 15 RPM hover is discarded at start-up", string.format("%.0f RPM", bad.ap.alt:hover_rpm(plant.rho(62))))
end

print("27. rcs reset forgets the learned RCS strength, keeps the layout")
do
  local layout = { bow_port = "electric_motor_6", bow_stbd = "electric_motor_1",
    stern_port = "electric_motor_0", stern_stbd = "electric_motor_4" }
  local sim = plant.new({ y = 150, lift = 900,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), yaw_b = 1.6, rcs_cap = 2000, rcs_map = layout } })
  local ok = sim.ap:command({ c = "rcs_reset" }, sim.s)
  local saved = sim.ap:saved()
  check(ok and math.abs(sim.ap.hdg:authority() - CFG.heading.yaw_authority) < 1e-9 and saved.yaw_b == nil,
    "turning strength back to the first guess, nothing saved for it",
    string.format("%.2f deg/s2, saved %s", sim.ap.hdg:authority(), tostring(saved.yaw_b)))
  check(math.abs(sim.ap.motion:sway_authority() - CFG.heading.sway_authority) < 1e-9,
    "sideways strength back to the first guess", string.format("%.3f", sim.ap.motion:sway_authority()))
  check(saved.rcs_map == layout, "the RCS corner layout is kept")
end

print("28. Plain hover to cruise: anticipate pusher lag before arrival")
do
  for _, target in ipairs({ 20, 30 }) do
    local sim = plant.new({ y = 200, lift = 900,
      saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
    sim.cmd("alt", 200)
    sim.cmd("mode", "HOVER")
    sim.run(40)
    sim.cmd("spd", target)
    sim.cmd("mode", "CRUISE")
    local start, peak, reached = sim.w.t, 0, nil
    sim.run(60, function(s2, s)
      peak = math.max(peak, s.v_fwd)
      if not reached and math.abs(s.v_fwd - target) < 1 then reached = s2.w.t - start end
    end)
    check(peak < target + 1, target .. " m/s overshoot under 1 m/s", string.format("peak %.3f", peak))
    check(reached ~= nil and reached <= 15, target .. " m/s reached within 15 s", tostring(reached))
    check(math.abs(sim.s.v_fwd - target) < 1, target .. " m/s held after 60 s",
      string.format("%.3f", sim.s.v_fwd))
    local score, id = sim.w.peak_flicker()
    check(score < 128, "bearing flicker stays below destruction threshold", tostring(id) .. ": " .. score)
  end
end

print("29. RCS off releases fore/aft station keeping, not cruise propulsion")
do
  local sim = plant.new({ y = 200, lift = 900, v_fwd = 5,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(2)
  check(sim.w.cmd.thrust_port < 0, "pushers are braking drift before handoff")
  sim.cmd("rcs_off")
  local released = true
  sim.run(6, function(s2)
    released = released and s2.bank.ch.thrust_port.desired == 0 and s2.bank.ch.thrust_stbd.desired == 0
    for _, id in ipairs({ "bow_port", "bow_stbd", "stern_port", "stern_stbd" }) do
      released = released and s2.bank.ch[id].desired == 0
    end
  end)
  check(released, "RCS off commands all horizontal station-keeping motors to zero")
  check(sim.w.cmd.thrust_port == 0 and sim.w.cmd.thrust_stbd == 0, "running pushers stop after paced handoff")
  check(math.abs(sim.s.y - 200) < 2, "altitude hold remains active")
  sim.w.vx, sim.w.vz = 0, -5
  sim.run(2)
  check(sim.w.cmd.thrust_port == 0 and sim.w.cmd.thrust_stbd == 0, "new fore/aft drift does not wake pushers")
  sim.cmd("rcs_on")
  local braking = false
  sim.run(20, function(s2) braking = braking or s2.w.cmd.thrust_port < 0 end)
  check(braking and math.abs(sim.s.v_fwd) < 0.8, "RCS on resumes braking the current drift",
    string.format("%.2f m/s", sim.s.v_fwd))
  sim.cmd("rcs_off")
  sim.cmd("spd", 10)
  sim.cmd("mode", "CRUISE")
  -- On a hull with almost no drag the steady thrust is near 0: check that the
  -- pushers drove it there, not the thrust at the last instant.
  local fwd_thrust = false
  sim.run(35, function(s2) fwd_thrust = fwd_thrust or s2.w.cmd.thrust_port > 0 end)
  check(fwd_thrust and math.abs(sim.s.v_fwd - 10) < 1,
    "nonzero CRUISE target still drives pushers with RCS off", string.format("%.2f m/s", sim.s.v_fwd))
  sim.cmd("spd", 0)
  local zero_target = true
  sim.run(6, function(s2)
    zero_target = zero_target and s2.bank.ch.thrust_port.desired == 0 and s2.bank.ch.thrust_stbd.desired == 0
  end)
  check(zero_target and sim.w.cmd.thrust_port == 0 and sim.w.cmd.thrust_stbd == 0,
    "zero-speed CRUISE also releases station keeping with RCS off")
end

print("30. Signed speed: reverse cruise, direction changes, and zero")
do
  local sim = plant.new({ y = 200, lift = 900,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(40)
  sim.cmd("spd", -10)
  sim.cmd("mode", "CRUISE")
  local start, reached, peak_back, astern = sim.w.t, nil, 0, false
  sim.run(35, function(s2, s)
    peak_back = math.max(peak_back, -s.v_fwd)
    astern = astern or s2.w.cmd.thrust_port < 0
    if not reached and math.abs(s.v_fwd + 10) < 1 then reached = s2.w.t - start end
  end)
  check(astern and math.abs(sim.s.v_fwd + 10) < 1,
    "negative target cruises astern", string.format("%.2f m/s", sim.s.v_fwd))
  check(reached ~= nil and reached <= 15 and peak_back < 11,
    "reverse arrival meets the forward timing and overshoot bounds",
    string.format("reach %.1f s, peak %.2f", reached or -1, peak_back))
  check(math.abs(sim.s.y - 200) < 2 and math.abs(util.wrap180(sim.s.hdg)) < HDG_CRUISE,
    "reverse cruise holds altitude and bow heading")
  sim.cmd("rcs_off")
  sim.run(5)
  check(math.abs(sim.s.v_fwd + 10) < 1, "RCS off maintains the explicit reverse speed",
    string.format("%.2f m/s", sim.s.v_fwd))
  sim.cmd("rcs_on")
  sim.cmd("spd", 10)
  local ahead_thrust = false
  sim.run(35, function(s2) ahead_thrust = ahead_thrust or s2.w.cmd.thrust_port > 0 end)
  check(ahead_thrust and math.abs(sim.s.v_fwd - 10) < 1,
    "reverse-to-forward transition crosses zero and settles", string.format("%.2f m/s", sim.s.v_fwd))
  sim.cmd("spd", -50)
  check(sim.ap.tgt.spd == -35, "reverse target clamps at minus 35")
  local max_back = 0
  sim.run(50, function(_, s) max_back = math.max(max_back, -s.v_fwd) end)
  check(max_back <= 35.5 and math.abs(sim.s.v_fwd + 35) < 1,
    "reverse speed obeys the same hard cap", string.format("peak %.2f, final %.2f", max_back, sim.s.v_fwd))
  sim.cmd("spd", 0)
  local forward_brake = false
  sim.run(25, function(s2) forward_brake = forward_brake or s2.w.cmd.thrust_port > 0 end)
  check(forward_brake and math.abs(sim.s.v_fwd) < 0.5,
    "zero target brakes reverse motion", string.format("%.2f m/s", sim.s.v_fwd))
  check(sim.w.cmd.thrust_port == 0 and sim.w.cmd.thrust_stbd == 0, "pushers rest after stopping")
end

print("31. Closed-loop altitude hold")
do
  -- The open-loop held RPM drifted out to the release band and back (2.15
  -- blocks peak to peak with this noise).
  math.randomseed(7)
  local sim = plant.new({ hover_rpm_sea = 900, noise = 0.15 })
  sim.cmd("alt", 150)
  sim.cmd("mode", "HOVER")
  sim.run(90)
  local m = watch()
  sim.run(180, m.hook)
  check(m.max_y - m.min_y <= 1.0, "180 s hover stays within 1 block peak to peak",
    string.format("min %.2f max %.2f", m.min_y, m.max_y))
  check(sim.ap.alt.phase == "HOLD", "phase reads HOLD", sim.ap.alt.phase)
end

print("32. A saved pusher strength at the learner's floor is not believed")
do
  local sim = plant.new({ saved = { A = 0.05, Dn = 1.77 } })
  check(sim.ap.spd.A == CFG.speed.accel_full, "starts from the first guess", tostring(sim.ap.spd.A))
end

-- Airborne at Y (default 200), heading north, bow axis confirmed.
local function nav_hull(y)
  local sim = plant.new({ y = y or 200, lift = 900, psi = 0,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", y or 200)
  sim.cmd("mode", "HOVER")
  sim.run(20)
  return sim
end

local function flat(sim, x, z)
  return math.sqrt((sim.w.x - x) ^ 2 + (sim.w.z - z) ^ 2)
end

print("33. NAV HOLD: a nearby point is reached by translation, not by turning")
do
  local sim = nav_hull()
  sim.cmd("goto", { x = 10, z = -6, y = 200, brg = 0 })
  local worst_hdg, late_d, t0, top = 0, 0, sim.w.t, 0
  sim.run(60, function(s2, s)
    worst_hdg = math.max(worst_hdg, math.abs(util.wrap180(s.hdg)))
    top = math.max(top, s.y)
    if s2.w.t - t0 > 40 then late_d = math.max(late_d, flat(s2, 10, -6)) end
  end)
  check(late_d <= 0.5, "within 0.5 blocks for the last 20 s", string.format("worst %.2f", late_d))
  check(worst_hdg <= 10, "heading never more than 10 deg from 0", string.format("worst %.2f", worst_hdg))
  check(top < 202, "a translated stop does not climb to the transit floor", string.format("top %.2f", top))
  check(sim.ap.nav.phase == "ARRIVED", "phase ARRIVED", tostring(sim.ap.nav.phase))
end

print("34. 15 deg/s turn cap: a 180 deg hover turn")
do
  local sim = nav_hull()
  sim.cmd("brg", 180)
  local t0, peak, within, over, near = sim.w.t, 0, nil, 0, false
  sim.run(80, function(s2, s)
    peak = math.max(peak, math.abs(s.yaw_rate))
    local e = util.wrap180(s.hdg - 180)
    if math.abs(e) < 20 then near = true end
    if near then over = math.max(over, e) end
    if not within and math.abs(e) <= 2 then within = s2.w.t - t0 end
  end)
  check(peak <= 16, "peak yaw rate at most 16 deg/s", string.format("%.1f", peak))
  check(within ~= nil and within <= 50, "within 2 deg of 180 by 50 s", tostring(within))
  check(over <= 2, "overshoot past 180 at most 2 deg", string.format("%.2f", over))
end

-- Run until NAV has been ARRIVED (and stayed) for hold seconds. Returns the
-- time ARRIVED was first seen.
local function fly_nav(sim, seconds, hook)
  local t0, arrived = sim.w.t, nil
  sim.run(seconds, function(s2, s)
    if hook then hook(s2, s) end
    if s2.ap.nav.phase == "ARRIVED" then arrived = arrived or (s2.w.t - t0) end
  end)
  return arrived
end

local FLOOR = CFG.nav.min_transit_alt

print("35. goto with a final bearing: climb above " .. FLOOR .. " first, descend over the point, turn")
do
  local sim = nav_hull()
  sim.cmd("goto", { x = 400, z = 300, y = 230, brg = 270 })
  local min_y, left_climb, over = math.huge, false, false
  local arrived = fly_nav(sim, 400, function(s2, s)
    local phase = s2.ap.nav.phase
    if phase ~= "CLIMB" then left_climb = true end
    if flat(s2, 400, 300) <= 3 then over = true end
    if left_climb and not over then min_y = math.min(min_y, s.y) end
  end)
  check(min_y >= FLOOR - 1.5, "cruises at " .. FLOOR .. " until over the point", string.format("min %.2f", min_y))
  check(arrived ~= nil, "ARRIVED within 400 s", tostring(arrived))
  local worst_d, worst_h, worst_y = 0, 0, 0
  sim.run(20, function(s2, s)
    worst_d = math.max(worst_d, flat(s2, 400, 300))
    worst_h = math.max(worst_h, math.abs(util.wrap180(s.hdg - 270)))
    worst_y = math.max(worst_y, math.abs(s.y - 230))
  end)
  -- The bearing is held with the hover deadzone, like every hover (HDG_HOVER).
  check(sim.ap.nav.phase == "ARRIVED" and worst_d <= 0.5 and worst_h <= HDG_HOVER and worst_y <= 1.0,
    "holds the point, bearing 270 (+-" .. HDG_HOVER .. ") and Y 230 for 20 s",
    string.format("d %.2f hdg %.2f y %.2f", worst_d, worst_h, worst_y))
  print(string.format("     arrived after %.1f s", arrived or -1))
end

print("36. goto lower: descend last")
do
  local sim = nav_hull(250)
  sim.cmd("goto", { x = 300, z = 0, y = 180, brg = 90 })
  local min_far, left_climb, over = math.huge, false, false
  local arrived = fly_nav(sim, 400, function(s2, s)
    if s2.ap.nav.phase ~= "CLIMB" then left_climb = true end
    if flat(s2, 300, 0) <= 3 then over = true end
    if left_climb and not over then min_far = math.min(min_far, s.y) end
  end)
  check(min_far >= FLOOR - 2, "stays at " .. FLOOR .. " until over the point", string.format("min %.2f", min_far))
  check(arrived ~= nil and math.abs(sim.s.y - 180) <= 1.0, "ends at Y 180",
    string.format("y %.2f, arrived %s", sim.s.y, tostring(arrived)))
end

print("37. Route: fly through a waypoint, stop at the last")
do
  local sim = nav_hull()
  sim.cmd("route_add", { x = 200, z = 0 })
  sim.cmd("route_add", { x = 200, z = 200, y = 200, brg = 180 })
  sim.cmd("route_go")
  local closest, gs_there, low = math.huge, 0, math.huge
  local arrived = fly_nav(sim, 400, function(s2, s)
    local d = flat(s2, 200, 0)
    if d < closest then closest, gs_there = d, math.sqrt(s2.w.vx ^ 2 + s2.w.vz ^ 2) end
    if s2.ap.nav.phase == "TRANSIT" then low = math.min(low, s.y) end
  end)
  check(gs_there >= 5, "does not stop at the fly-through waypoint",
    string.format("%.2f m/s at %.1f blocks", gs_there, closest))
  check(low >= FLOOR - 1.5, "both legs cruise at " .. FLOOR, string.format("min %.2f", low))
  check(arrived ~= nil and flat(sim, 200, 200) <= 0.5 and math.abs(util.wrap180(sim.s.hdg - 180)) <= 2
    and math.abs(sim.s.y - 200) <= 1.0,
    "ARRIVED at the last leg, bearing 180, back down at Y 200",
    string.format("d %.2f hdg %.2f y %.2f arrived %s", flat(sim, 200, 200), sim.s.hdg, sim.s.y, tostring(arrived)))
end

print("38. Docking moves: N blocks along one ship axis, N degrees of bearing")
do
  local sim = nav_hull()
  local function dock(move, n)
    local ok, msg = sim.ap:command({ c = "dock", v = { move = move, n = n } }, sim.s)
    assert(ok, msg)
  end
  -- Worst distance from (x, z) and altitude error over the last 10 s of t s.
  local function settle(t, x, z, y)
    local d, e, t0 = 0, 0, sim.w.t
    sim.run(t, function(s2, s)
      if s2.w.t - t0 > t - 10 then
        d = math.max(d, flat(s2, x, z))
        e = math.max(e, math.abs(s.y - y))
      end
    end)
    return d, e
  end
  local x0, z0 = sim.w.x, sim.w.z
  dock("fwd", 5) -- heading north: 5 blocks toward -Z
  local d, e = settle(40, x0, z0 - 5, 200)
  check(d <= 0.5 and e <= 0.5, "FWD 5 holds 5 blocks north", string.format("off %.2f, y err %.2f", d, e))
  dock("stbd", 2)
  d = settle(40, x0 + 2, z0 - 5, 200)
  check(d <= 0.5, "STBD 2 then holds 2 blocks east", string.format("off %.2f", d))
  dock("up", 5)
  d, e = settle(30, x0 + 2, z0 - 5, 205)
  check(e <= 0.5 and d <= 0.5, "UP 5 holds 5 blocks higher in place", string.format("y err %.2f off %.2f", e, d))
  dock("turn", 90)
  local worst_d = 0
  sim.run(60, function(s2) worst_d = math.max(worst_d, flat(s2, x0 + 2, z0 - 5)) end)
  check(math.abs(util.wrap180(sim.s.hdg - 90)) <= HDG_HOVER and worst_d <= 0.5,
    "BRG +90 turns in place", string.format("hdg %.1f, worst off %.2f", sim.s.hdg, worst_d))
  dock("fwd", 10) -- now facing east
  dock("fwd", 10)
  dock("fwd", 10)
  local top = 0
  sim.run(120, function(_, s) top = math.max(top, s.y) end)
  check(sim.ap.nav.phase == "ARRIVED" and flat(sim, x0 + 32, z0 - 5) <= 0.5,
    "three FWD 10 presses add up to 30 blocks east",
    string.format("%s, off %.2f", tostring(sim.ap.nav.phase), flat(sim, x0 + 32, z0 - 5)))
  check(top < 207, "docking never climbs to the transit floor", string.format("top %.2f", top))
  local ok = sim.ap:command({ c = "dock", v = { move = "fwd", n = 0 } }, sim.s)
  check(not ok, "a zero move is refused")
  sim.cmd("spd", 10)
  sim.cmd("mode", "CRUISE")
  ok = sim.ap:command({ c = "dock", v = { move = "fwd", n = 1 } }, sim.s)
  check(not ok, "docking moves are refused in CRUISE")
end

print("39. HOVER holds position on a hull with almost no drag")
do
  -- Drifting 1 m/s to starboard and 0.6 m/s ahead when HOVER engages.
  local sim = plant.new({ y = 200, lift = 900, psi = 0, v_side = 1, v_fwd = 0.6,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(30)
  local pt = sim.ap.hover_pt
  check(pt ~= nil, "the drift is stopped and a point is held")
  pt = pt or { x = 0, z = 0 }
  local worst = 0
  sim.run(120, function(s2) worst = math.max(worst, flat(s2, pt.x, pt.z)) end)
  check(worst <= 0.5, "stays within 0.5 blocks of it for 2 minutes", string.format("worst %.2f", worst))
  sim.ap:command({ c = "dock", v = { move = "stbd", n = 5 } }, sim.s)
  sim.run(60)
  check(flat(sim, pt.x + 5, pt.z) <= 0.5, "a dock move from HOVER starts from the held point",
    string.format("off %.2f", flat(sim, pt.x + 5, pt.z)))
end

print("40. Dock hold settles when the props spin up slower than modelled")
-- In game (2026-11-22) a dock hold swung +-12 blocks at +-3 m/s for minutes:
-- the props there reach a new RPM at about 25 RPM a tick, and asking for
-- up to max_accel kept them reversing too late. The old tuning diverged in
-- this model at 20 RPM a tick.
for _, slew in ipairs({ 20, 16 }) do
  local sim = plant.new({ y = 200, lift = 900, psi = 0, prop_slew = slew,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(20)
  local x, z = sim.w.x, sim.w.z - 5
  sim.w.vz = -3.5 -- already moving 3.5 m/s ahead when the move starts
  local ok, msg = sim.ap:command({ c = "dock", v = { move = "fwd", n = 5 } }, sim.s)
  assert(ok, msg)
  local worst, t0 = 0, sim.w.t
  sim.run(150, function(s2) if s2.w.t - t0 > 90 then worst = math.max(worst, flat(s2, x, z)) end end)
  check(worst <= 0.5, slew .. " RPM a tick: within 0.5 blocks of the point after 90 s",
    string.format("worst %.2f", worst))
end

print("41. Pusher strength: turns and mislearned saves")
do
  -- A save past max_accel_full is a mislearned value, not a hull: it is
  -- discarded.
  local bad = plant.new({ saved = { A = CFG.speed.max_accel_full * 1.2, Dn = 0, thrust_cap = CFG.motors.thrust_port.cap } })
  check(bad.ap.spd.A == CFG.speed.accel_full, "a saved A above max_accel_full falls back to the first guess",
    string.format("A %.1f", bad.ap.spd.A))
  -- A turn swings the velocity into the bow axis without any thrust; read
  -- as acceleration it skewed A by a third.
  local sim = nav_hull()
  sim.cmd("spd", 20)
  sim.cmd("mode", "CRUISE")
  sim.run(40)
  local before, lo = sim.ap.spd.A, math.huge
  sim.cmd("brg", 90)
  sim.run(60, function(s2) lo = math.min(lo, s2.ap.spd.A) end)
  check(lo >= 0.8 * before, "a 90 deg turn at 20 m/s keeps A within 20%",
    string.format("%.1f -> min %.1f", before, lo))
end

print("42. Station keeping: under 0.5 blocks in every direction")
-- In-game conditions: writes reach the props 0.4 s late, a slight steady push
-- and random gusts, and pusher or RCS strength a quarter to four times what
-- was learned in cruise (the live fore/aft swing came from 4x stronger
-- pushers than believed).
for _, case in ipairs({
  { "as learned", {} },
  { "pushers 4x stronger", { thrust_full = 128 } },
  { "pushers 4x weaker", { thrust_full = 8 } },
  { "RCS 3x stronger", { rcs_accel = 1.8 } },
  { "RCS 3x weaker", { rcs_accel = 0.2 } },
  { "moving 3 m/s when HOVER engages, slow props", { v_fwd = 3, prop_slew = 20, thrust_full = 128 } },
}) do
  math.randomseed(3)
  local o = { y = 200, lift = 900, psi = 30, pusher_delay = 8, rcs_delay = 8, gust = 0.1, push_x = 0.02, push_z = -0.02,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } }
  for k, v in pairs(case[2]) do o[k] = v end
  local sim = plant.new(o)
  sim.cmd("alt", 200)
  sim.cmd("brg", 30)
  sim.cmd("mode", "HOVER")
  sim.run(60)
  local pt = sim.ap.hover_pt or { x = math.huge, z = math.huge }
  local wx, wy, wz = 0, 0, 0
  sim.run(120, function(s2)
    wx = math.max(wx, math.abs(s2.w.x - pt.x))
    wz = math.max(wz, math.abs(s2.w.z - pt.z))
    wy = math.max(wy, math.abs(s2.w.y - 200))
  end)
  check(wx < 0.5 and wz < 0.5 and wy < 0.5, case[1] .. ": held within 0.5 blocks for 2 minutes",
    string.format("x %.2f z %.2f y %.2f", wx, wz, wy))
  local score, id = sim.w.peak_flicker()
  check(score < 128, case[1] .. ": bearing flicker stays below destruction threshold", tostring(id) .. ": " .. score)
end

print("43. Station keeping after a reboot keeps the learned strengths")
-- In game a reboot started from the speed loop's belief again, and the first
-- 40 s swung 2.5 blocks before each axis had relearned its gain.
do
  local function hull(saved, v0)
    math.randomseed(5)
    local sim = plant.new({ y = 200, lift = 900, psi = 30, pusher_delay = 8, rcs_delay = 8, gust = 0.1, thrust_full = 128, v_fwd = v0,
      saved = saved })
    sim.cmd("alt", 200)
    sim.cmd("brg", 30)
    sim.cmd("mode", "HOVER")
    return sim
  end
  local first = hull({ k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } }, 0)
  first.run(90)
  local saved = first.ap:saved()
  check(saved.station ~= nil and saved.station.f > 1.5 * saved.A * 0.82, "the stronger pushers are learned and saved",
    string.format("%s m/s^2 at full (speed loop: %.1f)", tostring(saved.station and saved.station.f), saved.A))
  local sim = hull(saved, 0.3)
  local pt, worst = nil, 0
  sim.run(90, function(s2)
    pt = pt or s2.ap.hover_pt
    if pt then worst = math.max(worst, math.sqrt((s2.w.x - pt.x) ^ 2 + (s2.w.z - pt.z) ^ 2)) end
  end)
  check(pt ~= nil and worst < 0.5, "after the reboot the point is held within 0.5 blocks from the start",
    string.format("worst %.2f", worst))
end

-- A hull at Y 600 with in-game write delay and light gusts, holding in HOVER.
local function trip_hull(o)
  math.randomseed(11)
  local opts = { y = 600, lift = 900, psi = 349, pusher_delay = 8, rcs_delay = 8, gust = 0.05,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } }
  for k, v in pairs(o or {}) do opts[k] = v end
  local sim = plant.new(opts)
  sim.cmd("alt", opts.y)
  sim.cmd("brg", opts.psi)
  sim.cmd("mode", "HOVER")
  sim.run(30)
  return sim
end

print("44. NAV turning in place holds its spot")
-- In game a 140 deg turn toward the course moved the hull 30 blocks: the
-- RCS pair that turns it also slid it sideways.
do
  local sim = trip_hull({ turn_slide = 8 })
  local x0, z0, worst, aligned = sim.w.x, sim.w.z, 0, false
  local h = math.rad(126)
  assert(sim.ap:command({ c = "goto", v = { x = x0 + 3000 * math.sin(h), z = z0 - 3000 * math.cos(h), y = 600 } }, sim.s))
  sim.run(60, function(s2, s)
    if math.abs(util.wrap180(s.hdg - 126)) < CFG.nav.align_deg then aligned = true end
    if not aligned then worst = math.max(worst, flat(s2, x0, z0)) end
  end)
  check(aligned and worst < 8, "a 137 deg turn moves the hull under 8 blocks (16 before)", string.format("worst %.2f", worst))
end

print("45. NAV arrival: stop first, then station keeping and the descent")
-- In game the hull entered HOLD at 2.9 m/s and passed the point by 10
-- blocks; the descent started while it passed over, paused when it drifted
-- off, fell 9-19 blocks below the pause and climbed back.
do
  local sim = trip_hull({ psi = 90 })
  local tx, tz = sim.w.x + 400, sim.w.z
  assert(sim.ap:command({ c = "goto", v = { x = tx, z = tz, y = 150, brg = 90 } }, sim.s))
  local past, off_descending, low, climb_back = 0, 0, math.huge, 0
  sim.run(400, function(s2, s)
    local ph = s2.ap.nav.phase
    if ph == "HOLD" or ph == "ARRIVED" then
      past = math.max(past, s2.w.x - tx)
      if s.vy < -0.5 then off_descending = math.max(off_descending, flat(s2, tx, tz)) end
      low = math.min(low, s.y)
      climb_back = math.max(climb_back, s.y - low)
    end
  end)
  check(past < 1, "never passes the point by a block (7.9 before)", string.format("%.2f", past))
  check(off_descending < 3, "descends only over the point", string.format("up to %.2f blocks off", off_descending))
  check(climb_back < 1, "never climbs back during the descent (6.4 before)", string.format("%.2f", climb_back))
  check(sim.ap.nav.phase == "ARRIVED" and flat(sim, tx, tz) < 0.5 and math.abs(sim.s.y - 150) < 0.5,
    "ARRIVED on the point at Y 150", string.format("%s, off %.2f, y %.2f", tostring(sim.ap.nav.phase), flat(sim, tx, tz), sim.s.y))
end

print("46. Pusher strength is kept at sea level and scaled by the air density")
-- Air at Y 600 is half as dense as at the ground: a strength learned up
-- there made the pushers several times stronger than believed low down.
-- (No write delay here: the learner does not model it, and it biases what
-- is learned low.)
do
  local sim = trip_hull({ psi = 90, pusher_delay = 0, rcs_delay = 0 })
  sim.cmd("spd", 20)
  sim.cmd("mode", "CRUISE")
  sim.run(40)
  sim.cmd("spd", 0)
  sim.run(30)
  sim.cmd("mode", "HOVER")
  sim.cmd("alt", 150)
  sim.run(150)
  local true_full = 32 * plant.rho(sim.s.y) / plant.rho(62)
  local believed = sim.ap.spd:accel_full(sim.s)
  check(math.abs(believed / true_full - 1) < 0.2, "learned at Y 600, believed within 20% at Y 150",
    string.format("believed %.1f, true %.1f m/s^2 at full", believed, true_full))
end

print("47. A ship that stops ticking pauses control")
-- In game the ship's chunk stopped ticking at Y 120: telemetry repeated the
-- same sample, the hover learner fitted 5100 RPM and the lift went to the
-- 5500 cap, ready to fling the hull up when it ticked again.
do
  local sim = plant.new({ y = 200, lift = 900, psi = 0,
    saved = { k = 10 / (plant.rho(62) * 900 * 900), bow = { x = 1, y = 0, z = 0 } } })
  sim.cmd("alt", 200)
  sim.cmd("mode", "HOVER")
  sim.run(40)
  local k0 = sim.ap.alt.k
  sim.w.frozen = true
  sim.run(600)
  local paused = false
  for _, a in ipairs(sim.ap:alerts(sim.s, sim.w.t)) do if a:find("CONTROL PAUSED", 1, true) then paused = true end end
  check(paused, "the pause is shown")
  check(math.abs(sim.ap.alt.k / k0 - 1) < 0.05, "the hover calibration is not relearned while frozen",
    string.format("k x%.2f", sim.ap.alt.k / k0))
  local hover = sim.ap.alt:hover_rpm(sim.s.rho)
  check(math.abs(sim.w.cmd.lift_bow_port - hover) < 0.1 * hover, "the lift waits at the hover RPM",
    string.format("%d RPM, hover %.0f", sim.w.cmd.lift_bow_port, hover))
  sim.w.frozen = false
  local lo, hi = math.huge, -math.huge
  sim.run(30, function(_, s) lo, hi = math.min(lo, s.y), math.max(hi, s.y) end)
  check(hi - 200 < 2 and 200 - lo < 2, "ticking again, altitude stays within 2 blocks",
    string.format("%.2f..%.2f", lo, hi))
end

print(failures == 0 and "ALL FLIGHT CHECKS PASSED" or (failures .. " FLIGHT CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
