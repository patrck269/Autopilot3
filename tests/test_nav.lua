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
A.eq(n.transit_alt, 200, "a translated stop keeps the current altitude (no climb to the floor)")
n:start({ { x = r + 6, z = 0, brg = 90 } }, s)
A.eq(n.phase, "CLIMB", "a stop " .. (r + 6) .. " blocks away is flown to")
local floor = cfg.nav.min_transit_alt
A.eq(n.transit_alt, floor, "transit is raised to min_transit_alt")
n:start({ { x = 5, z = 0 }, { x = 400, z = 0, y = floor + 60 } }, s)
A.eq(n.i, 2, "a fly-through leg already inside pass_radius is skipped")
A.eq(n.transit_alt, floor + 60, "climb first: the transit altitude is the highest one")
n:start({ { x = 400, z = 0, brg = 90 } }, { x = 0, z = 0, y = floor + 100, hdg = 0 })
A.eq(n.transit_alt, floor + 100, "already above the floor: transit stays at the current altitude")
cmd = cmdline.parse("dock stbd 5")
A.eq(cmd.c, "dock", "dock move")
A.eq(cmd.v.move, "stbd", "dock direction")
A.eq(cmd.v.n, 5, "dock blocks")
A.eq(cmdline.parse("dock turn -10").v.n, -10, "dock turn is signed")
A.eq(cmdline.parse("dock here").v.move, "here", "dock here")
none, err = cmdline.parse("dock left 5")
A.eq(none, nil, "unknown dock direction is refused")
A.eq(err, "dock fwd|aft|port|stbd|up|down <blocks> | dock turn <deg> | dock here", "dock usage")

-- Help pages: a 19-row terminal shows 15 help lines at a time.
local page_cmd, page = cmdline.parse("help 2")
A.eq(page_cmd, "help", "help with a page")
A.eq(page, 2, "help page number")
local n = #cmdline.HELP
local lines, top, shown, pages = cmdline.help_view(1, 15)
A.eq(#lines, math.min(15, n), "the first page fills the view")
A.eq(top, 1, "page 1 starts at the first line")
A.eq(pages, math.ceil(n / 15), "page count")
A.eq(shown, 1, "page 1 is page 1")
lines, top, shown = cmdline.help_view(16, 15)
A.eq(lines[#lines], cmdline.HELP[n], "the last page ends on the last line")
A.eq(#lines, math.min(15, n), "the last page is full: it starts earlier instead of leaving rows empty")
A.eq(shown, pages, "the last page reads as the last page")
lines, top = cmdline.help_view(-5, 15)
A.eq(top, 1, "scrolling above the top stops at line 1")
for i, l in ipairs(cmdline.HELP) do
  A.eq(#l <= 51, true, "help line " .. i .. " fits the 51-column terminal")
end

print("ALL NAV CHECKS PASSED")
