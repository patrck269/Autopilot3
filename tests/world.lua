-- Physics stand-in for a Valkyrien Skies hull on Clockwork propellers, with
-- ten fake Create Crafts & Additions electric motors and CC:VS ship/aero
-- APIs. No requires, so the same file runs in desktop Lua and inside CraftOS-PC.
--   * lift   = k * rho(y) * mean of rpm|rpm| over the four lift corners
--              (Clockwork blade thrust law); corner differences pitch and roll
--   * thrust = b * rho(y) * mean of rpm|rpm| over the two pushers, along the
--              bow, linear + quadratic drag
--   * RCS pullers: sway force and yaw torque, yaw damping
--   * pusher thrust that misses the centre of mass: yaw torque and nose dip
--   * props follow the motor with a short lag; the ground holds the hull
local W = {}

local RAD = math.pi / 180

W.DEFAULTS = {
  hover_rpm_sea = 900,  -- true hover RPM (every lift corner) at sea-level density
  thrust_full = 32,     -- forward m/s^2 with both pushers at thrust_rpm, sea level (measured in game)
  thrust_rpm = 10000,   -- the 3.0 hull's small pusher props need this RPM for thrust_full
  -- Drag measured in game with Eureka's helm brake off (2026-11-22): about
  -- 0.05 m/s^2 at 35 m/s, under 0.02 m/s^2 when coasting below 1 m/s.
  drag1 = 0.002,        -- linear drag, 1/s
  drag2 = 0.00004,      -- quadratic drag, 1/m
  side_drag = 0.002,
  rcs_accel = 0.6,      -- sway m/s^2 from one RCS at 2500 RPM
  yaw_accel = 2.0,      -- deg/s^2 from one RCS at 2500 RPM
  yaw_damp = 0.15,
  misalign = 0.0,       -- deg/s^2 of yaw per m/s^2 of pusher thrust
  dip = 0.0,            -- deg/s^2 nose down per m/s^2 of pusher thrust
  pitch_spring = 0.4,
  pitch_damp = 0.8,
  roll_spring = 0.4,
  roll_damp = 0.8,
  level_gain = 40,      -- deg/s^2 of pitch/roll per unit of lift difference (share of the total)
  pitch_load = 0,       -- deg/s^2 nose up from an off-centre load
  roll_load = 0,        -- deg/s^2 starboard down from an off-centre load
  prop_slew = 32,       -- Clockwork bearing: spin moves half way to the target each tick, at most this RPM
  cmd_delay = 0,        -- ticks before a pusher or RCS write reaches the prop (fore/aft recordings fit about 8;
                        -- the lift is left undelayed: altitude holds 0.25 blocks live, the model would not with 8)
  push_x = 0,           -- steady world-frame push on the hull, m/s^2 (a slight tilt of the lift, say)
  push_z = 0,
  gust = 0,             -- +- m/s^2 random push each tick, independent per axis
  ground_y = 64,
  noise = 0,            -- +- m/s added to each velocity reading
  v_side = 0,           -- starting sideways drift, m/s (+ = starboard)
  v_fwd = 0,            -- starting forward speed, m/s
}

local LIFT = { "lift_bow_port", "lift_bow_stbd", "lift_stern_port", "lift_stern_stbd" }
local PUSHERS = { thrust_port = true, thrust_stbd = true }
local LIFT_SET = {}
for _, id in ipairs(LIFT) do LIFT_SET[id] = true end

-- Diagonal RCS partners: one corner pulling alone strafes instead of turning.
local PARTNER = { bow_stbd = "stern_port", bow_port = "stern_stbd" }

local function ssq(x) return x * math.abs(x) end

local function qmul(a, b)
  return {
    w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
  }
end

local function axis_angle(x, y, z, ang)
  local s = math.sin(ang / 2)
  return { x = x * s, y = y * s, z = z * s, w = math.cos(ang / 2) }
end

-- Orientation for compass heading psi, pitch theta (nose up) and roll phi
-- (starboard down), degrees; bow = local +X, starboard = local +Z.
function W.quat(psi, theta, phi)
  local yaw_pitch = qmul(axis_angle(0, 1, 0, (90 - psi) * RAD), axis_angle(0, 0, 1, theta * RAD))
  return qmul(yaw_pitch, axis_angle(1, 0, 0, (phi or 0) * RAD))
end

function W.rho(y)
  return 1.225 * math.exp(-(y - 62) / 700)
end

-- motors: cfg.motors. opts: overrides of DEFAULTS plus y, psi, lift (start
-- RPM of every lift corner) and rpm (start RPM per motor id).
function W.new(motors, opts, gravity)
  opts = opts or {}
  local p = {}
  for k, v in pairs(W.DEFAULTS) do p[k] = v end
  for k, v in pairs(opts) do p[k] = v end
  gravity = gravity or 10

  local sea = W.rho(62)
  local w = {
    p = p,
    x = 0, y = opts.y or p.ground_y, z = 0,
    vx = 0, vy = 0, vz = 0,
    psi = opts.psi or 0, r = 0, theta = 0, q = 0, phi = 0, pr = 0,
    rpm = {}, cmd = {}, writes = 0, queue = {},
    flick = {}, peak = {}, -- Create flicker score of each motor's prop bearing
    devices = {},
    ticks = 0, lonely = 0, lonely_run = 0, lonely_max = 0, -- RCS corner pulling without its diagonal partner
    split_run = 0, pusher_split_max = 0, -- the two pushers set to different RPM
  }
  do
    local a = w.psi * RAD
    w.vx = p.v_fwd * math.sin(a) + p.v_side * math.cos(a)
    w.vz = -p.v_fwd * math.cos(a) + p.v_side * math.sin(a)
  end
  local k_lift = gravity / (sea * p.hover_rpm_sea ^ 2)
  local k_thrust = p.thrust_full / (sea * p.thrust_rpm ^ 2)

  -- GeneratingKineticBlockEntity.applyNewSpeed detaches and reattaches the
  -- network. Budget 5 flicker points per downstream stop/start transition:
  -- up to 10 per running-speed change, including the prop bearing.
  -- The score drops 1 a tick; a bearing past 128 is destroyed. Starting
  -- from or stopping at 0 is one transition, otherwise budget two.
  local function bump(id, from, to)
    local n = (from == 0 or to == 0) and 5 or 10
    w.flick[id] = w.flick[id] + n
    if w.flick[id] > w.peak[id] then w.peak[id] = w.flick[id] end
  end

  for id, c in pairs(motors) do
    local start = 0
    if LIFT_SET[id] and opts.lift then start = opts.lift end
    if opts.rpm and opts.rpm[id] then start = opts.rpm[id] end
    w.rpm[id] = start
    w.cmd[id] = start
    w.flick[id] = 0
    w.peak[id] = 0
    w.devices[id] = {
      setSpeed = function(v)
        assert(type(v) == "number", "setSpeed expects a number")
        assert(v == math.floor(v), "setSpeed should get an integer, got " .. v)
        assert(math.abs(v) <= c.cap, id .. " over cap: " .. v)
        -- The lift and RCS props only ever pull: positive RPM (or 0).
        if not PUSHERS[id] then assert(v >= 0, id .. " given negative RPM: " .. v) end
        if v ~= w.cmd[id] then bump(id, w.cmd[id], v) end
        w.cmd[id] = v
        table.insert(w.queue, { at = w.ticks + (LIFT_SET[id] and 0 or p.cmd_delay), id = id, v = v })
        w.writes = w.writes + 1
      end,
      getSpeed = function() return w.cmd[id] end,
    }
  end

  -- Highest flicker score any bearing reached, and which.
  function w.peak_flicker()
    local m, at = 0, nil
    for id, v in pairs(w.peak) do
      if v > m then m, at = v, id end
    end
    return m, at
  end

  w.ship = {
    getId = function() return 7 end,
    getSlug = function() return "test-hull" end,
    getWorldspacePosition = function() return { x = w.x, y = w.y, z = w.z } end,
    getVelocity = function()
      local function jitter() return (math.random() * 2 - 1) * p.noise end
      return { x = w.vx + jitter(), y = w.vy + jitter(), z = w.vz + jitter() }
    end,
    -- CC:VS's rom/apis/ship.lua wraps the native {x,y,z,w} as a quaternion
    -- object: vector part in .v, scalar part in .a.
    getQuaternion = function()
      local q = W.quat(w.psi, w.theta, w.phi)
      return { v = { x = q.x, y = q.y, z = q.z }, a = q.w }
    end,
    getAngularVelocity = function() return { x = 0, y = -w.r * RAD, z = 0 } end,
    getMass = function() return 50000 end,
  }
  w.aero = { getAirDensity = function(y) return W.rho(y or w.y) end }

  -- Advance the hull by dt seconds (one game tick is 0.05).
  local target = {}
  for id in pairs(motors) do target[id] = w.cmd[id] end
  function w.step(dt)
    local rho = W.rho(w.y)
    -- Writes reach the props cmd_delay ticks later.
    local keep = {}
    for _, q in ipairs(w.queue) do
      if q.at <= w.ticks then target[q.id] = q.v else keep[#keep + 1] = q end
    end
    w.queue = keep
    for id, v in pairs(target) do
      -- PropellerBearingBlockEntity.tick: omega += clamp((target - omega) / 2, +-32 RPM)
      w.rpm[id] = w.rpm[id] + math.max(-p.prop_slew, math.min(p.prop_slew, (v - w.rpm[id]) / 2))
      w.flick[id] = math.max(0, w.flick[id] - 1)
    end
    w.ticks = w.ticks + 1
    local alone = false
    for a, b in pairs(PARTNER) do
      if (w.cmd[a] ~= 0) ~= (w.cmd[b] ~= 0) then alone = true end
    end
    if alone then
      w.lonely = w.lonely + 1
      w.lonely_run = w.lonely_run + 1
      if w.lonely_run > w.lonely_max then w.lonely_max = w.lonely_run end
    else
      w.lonely_run = 0
    end
    if w.cmd.thrust_port ~= w.cmd.thrust_stbd then
      w.split_run = w.split_run + 1
      if w.split_run > w.pusher_split_max then w.pusher_split_max = w.split_run end
    else
      w.split_run = 0
    end
    local function f(id) return ssq(w.rpm[id]) end
    local bp, bs = f("lift_bow_port"), f("lift_bow_stbd")
    local sp, ss = f("lift_stern_port"), f("lift_stern_stbd")
    local F = bp + bs + sp + ss
    local a_lift = k_lift * rho * F / 4 - gravity
    local a_thr = k_thrust * rho * (f("thrust_port") + f("thrust_stbd")) / 2
    local rc = 1 / (2500 * 2500)
    -- p.at: which motor's props really sit at each RCS corner (default: the
    -- one named for it). Lets a test build a hull whose labels are wrong.
    local function at(position) return f(p.at and p.at[position] or position) * rc end
    local rbs, rbp = at("bow_stbd"), at("bow_port")
    local rss, rsp = at("stern_stbd"), at("stern_port")
    local a_side = p.rcs_accel * (rbs + rss - rbp - rsp) * rho / sea
    local yaw_acc = p.yaw_accel * ((rbs - rbp) - (rss - rsp)) * rho / sea
      - p.yaw_damp * w.r + p.misalign * a_thr

    local fx, fz = math.sin(w.psi * RAD), -math.cos(w.psi * RAD)
    local rx, rz = -fz, fx
    local vf = w.vx * fx + w.vz * fz
    local vs = w.vx * rx + w.vz * rz
    local af = a_thr - p.drag1 * vf - p.drag2 * vf * math.abs(vf)
    local as = a_side - p.side_drag * vs
    local gx = p.push_x + (p.gust > 0 and (math.random() * 2 - 1) * p.gust or 0)
    local gz = p.push_z + (p.gust > 0 and (math.random() * 2 - 1) * p.gust or 0)
    w.vx = w.vx + (af * fx + as * rx + gx) * dt
    w.vz = w.vz + (af * fz + as * rz + gz) * dt
    w.vy = w.vy + a_lift * dt
    w.x = w.x + w.vx * dt
    w.z = w.z + w.vz * dt
    w.y = w.y + w.vy * dt
    local grounded = false
    if w.y <= p.ground_y then
      w.y = p.ground_y
      grounded = true
      if w.vy < 0 then w.vy = 0 end
      w.vx, w.vz = w.vx * 0.9, w.vz * 0.9
    end
    w.r = w.r + yaw_acc * dt
    w.psi = (w.psi + w.r * dt) % 360
    -- Pitch and roll: the props' differences and any off-centre load, held
    -- by the hull's own stability; the ground holds the hull level.
    local q_acc = -p.dip * a_thr - p.pitch_spring * w.theta - p.pitch_damp * w.q
    local p_acc = -p.roll_spring * w.phi - p.roll_damp * w.pr
    if not grounded then
      q_acc = q_acc + p.pitch_load
      p_acc = p_acc + p.roll_load
      if F > 0 then
        q_acc = q_acc + p.level_gain * ((bp + bs) - (sp + ss)) / F
        p_acc = p_acc - p.level_gain * ((bs + ss) - (bp + sp)) / F
      end
    end
    w.q = w.q + q_acc * dt
    w.theta = w.theta + w.q * dt
    w.pr = w.pr + p_acc * dt
    w.phi = w.phi + w.pr * dt
  end

  return w
end

return W
