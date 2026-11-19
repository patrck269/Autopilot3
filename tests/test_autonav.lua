package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local config = require("config")
local autonav = require("autonav")
local cfg = config.default()

local st = {
  waypoint_x = 0, waypoint_z = -1000,
  profile = "warp", phase = "climb", cruise_alt = 400,
  bearing_target = 0,
}
local s = { x=0, y=395, z=0, forward_speed=0 }
autonav.step(st, s, cfg)
A.eq(st.phase, "track", "climb transition")
A.eq(st.alt_target, 400, "climb altitude")

s.y = 400
autonav.step(st, s, cfg)
A.near(st.speed_target, math.sqrt(2 * 995), 1e-10, "warp braking profile")
A.near(st.speed_target, 44.6, 0.1, "warp speed")

st.waypoint_z = -8
s.forward_speed = 0.2
autonav.step(st, s, cfg)
A.eq(st.phase, "descend", "track transition")

s.y = 331
autonav.step(st, s, cfg)
A.eq(st.phase, "hold", "descent transition")
A.eq(st.alt_target, 329, "arrival altitude")
A.eq(st.speed_target, 0, "arrival speed")
