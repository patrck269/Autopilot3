-- Display ground speed must follow displacement, not an accumulating velocity API.
-- Run from the repo root: lua tests/test_telemetry.lua
package.path = "./?.lua;" .. package.path
local A = require("tests.assert")
local telemetry = require("ap3.telemetry")
local cfg = { frame = { up = { x = 0, y = 1, z = 0 }, forward = { x = 1, y = 0, z = 0 } } }
local now = 0
local pos = { x = 100, y = 200, z = 300 }
local vel = { x = 20, y = 0, z = 0 }
local q = { x = 0, y = 0, z = 0, w = 1 }
local tel = telemetry.new(cfg, {
  clock = function() return now end,
  ship = {
    getWorldspacePosition = function() return pos end,
    getVelocity = function() return vel end,
    getQuaternion = function() return q end,
  },
})

local s = tel.read()
A.eq(s.ground.v_fwd, nil, "one position cannot establish speed")
for i = 1, 10 do
  now = i * 0.1
  vel.x = 20 + i * 3
  s = tel.read()
  A.near(s.ground.v_fwd, 0, 1e-9, "stationary hull has no forward motion")
  A.near(s.ground.gs, 0, 1e-9, "stationary hull has no ground speed")
  A.eq(s.ground.track, nil, "stationary hull has no ground track")
end

-- Irregular sample spacing and diagonal movement: 3 east, 4 north per second.
now, pos.x, pos.z = 1.4, 101.2, 298.4
s = tel.read()
A.near(s.ground.gs, 5, 1e-9, "ground speed uses elapsed sample time")
A.near(s.ground.v_fwd, 3, 1e-9, "forward projection follows the bow")
A.near(s.ground.v_side, -4, 1e-9, "sideways projection follows the hull")
A.near(s.ground.track, math.deg(math.atan(3, 4)), 1e-9, "track follows displacement")

now, pos.x = 1.6, 100.2
s = tel.read()
A.near(s.ground.v_fwd, -5, 1e-9, "backing up gives negative forward speed")
A.near(s.ground.gs, 5, 1e-9, "ground speed remains unsigned in reverse")

-- Learning a different bow must rotate the projection, not discard position history.
tel.set_forward({ x = 0, y = 0, z = -1 })
now, pos.z = 1.8, 297.8
s = tel.read()
A.near(s.ground.v_fwd, 3, 1e-9, "learned bow is used without a missing speed sample")
A.near(s.ground.v_side, 0, 1e-9, "learned bow rotates sideways speed")

-- Attitude changes alone must not invent ground motion.
q = { x = 0, y = math.sin(math.pi / 4), z = 0, w = math.cos(math.pi / 4) }
now = 2
s = tel.read()
A.near(s.ground.gs, 0, 1e-9, "rotation at a fixed position has no ground speed")

-- A repeated or reset clock must not divide by zero or reuse a false speed.
pos.x = pos.x + 1
s = tel.read()
A.eq(s.ground.gs, nil, "duplicate sample time has no measurable speed")
now = 0
s = tel.read()
A.eq(s.ground.gs, nil, "clock reset starts a new position baseline")
now, pos.x = 0.5, pos.x - 2
s = tel.read()
A.near(s.ground.gs, 4, 1e-9, "measurement recovers after clock reset")

print("ALL TELEMETRY CHECKS PASSED")
