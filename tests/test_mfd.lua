package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local canvas = require("canvas")
local mfd = require("mfd")

local tabs = mfd.tabs(57, 38)
A.eq(#tabs, 5, "tab count")
A.eq(tabs[1].h, 3, "tab height")
A.eq(tabs[1].y, 36, "tab row")
A.eq(tabs[5].x + tabs[5].w - 1 <= 57, true, "tabs fit")
local narrow = mfd.tabs(20, 20)
A.eq(narrow[1].y, 15, "two-row first tabs")
A.eq(narrow[4].y, 18, "two-row second tabs")

local pages = mfd.assign({"monitor_2","monitor_0","monitor_1"}, {monitor_1="NAV"})
A.eq(pages.monitor_1, "NAV", "saved page")
A.eq(pages.monitor_0, "FLT", "first missing page")
A.eq(pages.monitor_2, "BOMB", "second missing page")
mfd.select(pages, "monitor_0", "NAV")
A.eq(pages.monitor_0, "NAV", "selected page")
A.eq(pages.monitor_1, "FLT", "page swap")

local view = {
  mode="standby", emergency=false, bombs={size=1,used={},doors_open=false},
  bomb_sizes={1,3,5,10,"all"}, bomb_relays={}, bombs_left=0,
  missing={}, motor_states={}, logs={},
}
local layout = mfd.layout("BOMB", 57, 38, view)
A.eq(layout.bay.orientation, "vertical", "vertical bay")
local action = mfd.hit(layout, layout.tabs, tabs[2].x, tabs[2].y)
A.eq(action.type, "page", "tab hit")
A.eq(action.page, "BOMB", "tab page")
local open
for _, control in ipairs(layout.buttons) do
  if control.label == "OPEN DOORS" then open = control end
end
A.eq(open ~= nil, true, "open doors control")
action = mfd.hit(layout, layout.tabs, open.x + 1, open.y + 1)
A.eq(action.type, "doors", "door hit")
A.eq(action.open, true, "open action")
A.eq(mfd.layout("BOMB", 36, 24, view).bay.orientation, "small", "small bay fallback")

local colors = {white=1,black=32768,blue=2048,lime=32,red=16384,lightBlue=8,gray=128,yellow=16}
local c = canvas.new(20, 5, colors)
canvas.paint(c, 1, 1, "test", colors.white, colors.black)
local writes = 0
local mon = {
  setCursorPos=function() end,
  blit=function() writes=writes+1 end,
}
local cache = {}
canvas.flush(cache, "m", mon, c)
A.eq(writes, 5, "initial canvas flush")
canvas.flush(cache, "m", mon, c)
A.eq(writes, 5, "unchanged canvas skipped")
