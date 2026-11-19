package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local attitude = require("attitude")

local axes = attitude.axes("+x")
A.eq(axes.forward.x, 1, "forward x")
A.eq(axes.right.z, 1, "right z")
local s = attitude.sample(
  { x = 10, y = 20, z = 30 },
  { x = 4, y = 2, z = 3 },
  { x = 0, y = 0, z = 0, w = 1 },
  nil, 0.05, "+x")
A.eq(s.x, 10, "position x")
A.eq(s.forward_speed, 4, "forward speed")
A.eq(s.side_speed, 3, "side speed")
A.near(s.heading, math.pi / 2, 1e-12, "heading")
A.eq(s.pitch_rate, 0, "initial pitch rate")

local prev = { pitch = 0.1, roll = -0.2, heading = -math.pi + 0.01 }
local next_sample = attitude.sample(
  { x = 0, y = 0, z = 0 },
  { x = 0, y = 0, z = 0 },
  { x = 0, y = 0, z = 0, w = 1 },
  prev, 0.1, "+z")
A.near(next_sample.yaw_rate, -0.1, 1e-10, "wrapped yaw rate")

local ok, err = pcall(attitude.axes, "north")
A.eq(ok, false, "bad forward axis fails")
A.eq(tostring(err):match("forward_axis must be %+x, %-x, %+z or %-z") ~= nil, true, "axis error")
ok, err = pcall(attitude.sample, {x=0,y=0,z=0}, {x=0,y=0,z=0/0}, {x=0,y=0,z=0,w=1}, nil, 0.05, "+x")
A.eq(ok, false, "non-finite telemetry fails")
A.eq(tostring(err):match("invalid ship telemetry") ~= nil, true, "telemetry error")
