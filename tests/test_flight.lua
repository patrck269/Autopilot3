package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local config = require("config")
local flight = require("flight")
local cfg = config.default()

local function sample(values)
  local s = {
    x=0, y=100, z=0, vx=0, vy=0, vz=0,
    forward_speed=0, side_speed=0, heading=0,
    pitch=0, roll=0, pitch_rate=0, roll_rate=0, yaw_rate=0, dt=0.05,
  }
  for key, value in pairs(values or {}) do s[key] = value end
  return s
end

local st = flight.new_state(cfg)
st.mode = "semi"
st.alt_target = 150
st.bearing_target = 0
local y, vy = 100, 0
for _ = 1, 120 / 0.05 do
  local s = sample({ y=y, vy=vy })
  local out = flight.step(st, s, cfg)
  local mean = (out.elev_pb + out.elev_ps + out.elev_sb + out.elev_ss) / 4
  local accel = 10 * ((mean / 600) ^ 1.2 - 1)
  vy = vy + accel * s.dt
  y = y + vy * s.dt
end
A.near(y, 150, 0.5, "vertical target")
A.near(st.hover_rpm, 600, 12, "learned hover")

st = flight.new_state(cfg)
st.mode = "semi"
st.alt_target = 100
st.bearing_target = 0
local out = flight.step(st, sample({ pitch=math.rad(5) }), cfg)
A.eq(out.elev_pb < out.elev_ps, true, "nose-up port correction")
A.eq(out.elev_sb < out.elev_ss, true, "nose-up starboard correction")

st = flight.new_state(cfg)
st.mode = "semi"
st.alt_target = 100
st.bearing_target = 0
out = flight.step(st, sample({ roll=math.rad(5) }), cfg)
A.eq(out.elev_sb > out.elev_pb, true, "starboard bow roll correction")
A.eq(out.elev_ss > out.elev_ps, true, "starboard stern roll correction")

st = flight.new_state(cfg)
st.mode = "semi"
st.alt_target = 100
st.bearing_target = math.rad(10)
out = flight.step(st, sample(), cfg)
A.eq(out.rcs_sb > 0, true, "right turn bow starboard")
A.eq(out.rcs_ps > 0, true, "right turn stern port")
A.eq(out.rcs_pb, 0, "right turn bow port off")
A.eq(out.rcs_ss, 0, "right turn stern starboard off")

st.emergency = true
out = flight.step(st, sample(), cfg)
for role, rpm in pairs(out) do A.eq(rpm, 0, role .. " emergency") end
st.emergency = false
st.mode = "standby"
A.eq(flight.step(st, sample(), cfg), nil, "standby output")

st = flight.new_state(cfg)
A.eq(flight.enter(st, "auto", sample(), cfg), "set waypoint X and Z first", "auto waypoint guard")
