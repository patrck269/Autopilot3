-- Typed NAV commands and the NAV state that does not need a flight.
-- Run from the repo root: lua tests/test_nav.lua
package.path = "./?.lua;" .. package.path
local A = require("tests.assert")
local cmdline = require("ap3.cmdline")
local nav = require("ap3.nav")
local cfg = dofile("ap3/config.lua")

local cmd = cmdline.parse("goto 10 20")
A.eq(cmd.c, "goto", "goto with coordinates")
A.eq(cmd.v.x, 10, "goto X")
A.eq(cmd.v.z, 20, "goto Z")
A.eq(cmd.v.y, nil, "goto without Y keeps the altitude")
A.eq(cmd.v.brg, nil, "goto without BRG has no final bearing")
cmd = cmdline.parse("GOTO 10 20 230 270")
A.eq(cmd.v.y, 230, "goto Y")
A.eq(cmd.v.brg, 270, "goto BRG")

cmd = cmdline.parse("goto home")
A.eq(cmd.c, "goto", "goto a waypoint")
A.eq(cmd.v.name, "home", "goto a waypoint by name")

local none, err = cmdline.parse("goto 10")
A.eq(none, nil, "goto with one number is refused")
A.eq(err, "goto X Z [Y] [BRG] | goto <name>", "goto usage")

none, err = cmdline.parse("wp save 9x")
A.eq(none, nil, "a name starting with a digit is refused")
A.eq(err, nav.NAME_ERROR, "waypoint name rule")
none, err = cmdline.parse("wp save abcdefghijklm")
A.eq(err, nav.NAME_ERROR, "a 13-character name is refused")
A.eq(cmdline.parse("wp save home_2").v, "home_2", "letters, digits and _ are a name")

A.eq(cmdline.parse("route").c, "route_list", "bare route lists it")
cmd = cmdline.parse("route add 1 2 3 90")
A.eq(cmd.c, "route_add", "route add")
A.eq(cmd.v.brg, 90, "route add with a bearing")
A.eq(cmdline.parse("route add home").v.name, "home", "route add a waypoint")
A.eq(cmdline.parse("rec on").c, "rec_on", "recorder on")

-- Saved file: bad entries are dropped one by one.
local n = nav.new(cfg, {
  points = { ok = { x = 1, z = 2 }, bad = { x = "a", z = 2 } },
  route = { { x = 1, z = 1 }, { z = 3 } },
})
A.eq(n.points.ok ~= nil, true, "a valid waypoint loads")
A.eq(n.points.bad, nil, "a waypoint with a bad X is dropped")
A.eq(#n.route, 1, "a route leg without X is dropped")
local back = n:saved()
A.eq(back.points.ok.x, 1, "saved waypoints round-trip")
A.eq(#back.route, 1, "saved route round-trips")

-- A stop within translate_radius is reached by translation (HOLD at
-- once); further away the leg starts with CLIMB.
local s = { x = 0, z = 0, y = 200, hdg = 0 }
local r = cfg.nav.translate_radius
n:start({ { x = r - 4, z = 0 } }, s)
A.eq(n.phase, "HOLD", "a stop " .. (r - 4) .. " blocks away is translated to")
A.eq(n.hold_brg, 0, "without a bearing the stop keeps the current heading")
n:start({ { x = r + 6, z = 0, brg = 90 } }, s)
A.eq(n.phase, "CLIMB", "a stop " .. (r + 6) .. " blocks away is flown to")
A.eq(n.transit_alt, 200, "transit altitude starts at the current altitude")
n:start({ { x = 5, z = 0 }, { x = 400, z = 0, y = 260 } }, s)
A.eq(n.i, 2, "a fly-through leg already inside pass_radius is skipped")
A.eq(n.transit_alt, 260, "climb first: the transit altitude is the higher one")

print("ALL NAV CHECKS PASSED")
