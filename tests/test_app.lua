package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")
local app = require("app")
local config = require("config")
local mfd = require("mfd")

local cfg = config.default()
local now, timer_id = 0, 0
local devices, types, names = {}, {}, {}
local relay_events, motor_events = {}, {}
local latest_serialized

local function serialize(value)
  local kind = type(value)
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "string" then return string.format("%q", value) end
  if kind == "table" then
    local parts = {"{"}
    for key, item in pairs(value) do
      parts[#parts+1] = "["..serialize(key).."]="..serialize(item)..","
    end
    parts[#parts+1] = "}"
    return table.concat(parts)
  end
  error("cannot serialize "..kind)
end

local files = {}
local fs = {}
function fs.exists(path) return files[path] ~= nil end
function fs.delete(path) files[path] = nil end
function fs.move(source, dest) files[dest], files[source] = files[source], nil end
function fs.open(path, mode)
  if mode == "w" then
    return {write=function(body) files[path]=body end, close=function() end}
  end
  if files[path] == nil then return nil end
  return {readAll=function() return files[path] end, close=function() end}
end

local function add(name, kind, dev)
  names[#names+1], types[name], devices[name] = name, kind, dev
end
for role, id in pairs(cfg.motors) do
  local name = config.motor_name(id)
  add(name, "electric_motor", {
    setSpeed=function(rpm) motor_events[#motor_events+1]={role=role,rpm=rpm} end,
    getSpeed=function() return 0 end,
  })
end
for id = 13, 59 do
  add(config.relay_name(id), "redstone_relay", {
    setOutput=function(side, value)
      if id == 25 and value then
        local state = latest_serialized and assert(load("return "..latest_serialized))() or nil
        A.eq(state ~= nil and state.bombs.used[25], true, "used persisted before trigger")
      end
      relay_events[#relay_events+1]={id=id,side=side,value=value}
    end,
  })
end
local function monitor(w,h)
  return {
    setTextScale=function() end, getSize=function() return w,h end,
    setCursorPos=function() end, blit=function() end,
  }
end
add("monitor_0", "monitor", monitor(57,38))
add("monitor_1", "monitor", monitor(36,24))

local run_all_calls = 0
local term_rows, term_row = {}, 1
local fake_term = {
  getSize=function() return 51,19 end,
  setCursorPos=function(_, row) term_row=row end,
  setTextColor=function() end,
  setBackgroundColor=function() end,
  clear=function() term_rows={} end,
  write=function(text) term_rows[term_row]=text end,
}
local env = {
  peripheral={
    getNames=function() return names end,
    getType=function(name) return types[name] end,
    wrap=function(name) return devices[name] end,
  },
  ship={
    getWorldspacePosition=function() return {x=0,y=250,z=0} end,
    getVelocity=function() return {x=0,y=0,z=0} end,
    getQuaternion=function() return {x=0,y=0,z=0,w=1} end,
  },
  clock=function() return now end,
  start_timer=function() timer_id=timer_id+1 return timer_id end,
  run_all=function(fns) run_all_calls=run_all_calls+1 for _,fn in ipairs(fns) do fn() end end,
  term=fake_term, colors={white=1,black=32768,blue=2048,lime=32,red=16384,lightBlue=8,gray=128,yellow=16},
  keys={getName=function(code) return tostring(code) end},
  fs=fs,
  textutils={
    serialize=function(value) latest_serialized=serialize(value); return latest_serialized end,
    unserialize=function(body) local fn=load("return "..body); return fn and fn() or nil end,
  },
}

local a = app.new(env, cfg)
a:start()
a:control_tick()
a:redraw_all()
A.eq(term_rows[1]:match("^AUTOPILOT 3%.0 STANDBY") ~= nil, true, "terminal banner")
A.eq(term_rows[16]:match("^Missing: none") ~= nil, true, "terminal peripherals")
relay_events = {}
A.eq(a.pages.monitor_0, "FLT", "first monitor page")
A.eq(a.pages.monitor_1, "BOMB", "second monitor page")

local tabs = mfd.tabs(57,38)
local bomb_tab
for _, tab in ipairs(tabs) do if tab.page == "BOMB" then bomb_tab=tab end end
a:handle_event("monitor_touch", "monitor_0", bomb_tab.x+1, bomb_tab.y+1)
A.eq(a.pages.monitor_0, "BOMB", "touched bomb page")
A.eq(a.pages.monitor_1, "FLT", "page swap after touch")

local function touch_label(label)
  local control
  for _, item in ipairs(a.layouts.monitor_0.buttons) do if item.label == label then control=item end end
  A.eq(control ~= nil, true, label.." exists")
  a:handle_event("monitor_touch", "monitor_0", control.x+1, control.y+1)
end
touch_label("OPEN DOORS")
local door_on = 0
for _, event in ipairs(relay_events) do if event.id==59 and event.value then door_on=door_on+1 end end
A.eq(door_on, 6, "door relay six sides on")

now = 1
touch_label("DROP 1")
A.eq(a.last_message, "doors opening 2s", "early drop refused")
now = 3
touch_label("DROP 1")
A.eq(a.bombs.used[25], true, "bomb 25 used")
local trigger_on = 0
for _, event in ipairs(relay_events) do if event.id==25 and event.value then trigger_on=trigger_on+1 end end
A.eq(trigger_on, 6, "bomb trigger six sides on")

now = 4
a:control_tick()
a:apply({type="mode",mode="semi"})
motor_events, run_all_calls = {}, 0
a:control_tick()
A.eq(run_all_calls, 1, "motor writes batched")
A.eq(#motor_events, 10, "all motors written")
a:control_tick()
A.eq(run_all_calls, 1, "unchanged motor writes skipped")

a.flight.bearing_target = a.sample.heading + math.rad(10)
now = 5
a:control_tick()
A.eq(a.motor_cache.rcs_sb > 0, true, "RCS active before CLI toggle")
A.eq(a.motor_cache.rcs_ps > 0, true, "opposed RCS active before CLI toggle")
files[cfg.rcs_disable_file] = "disabled"
a:handle_event("autopilot_rcs_changed")
now = 6
a:control_tick()
A.eq(a.rcs_disabled, true, "RCS disable flag applied")
A.eq(a.motor_cache.rcs_pb, 0, "port-bow RCS killed")
A.eq(a.motor_cache.rcs_ps, 0, "port-stern RCS killed")
A.eq(a.motor_cache.rcs_sb, 0, "starboard-bow RCS killed")
A.eq(a.motor_cache.rcs_ss, 0, "starboard-stern RCS killed")
files[cfg.rcs_disable_file] = nil
a:handle_event("autopilot_rcs_changed")
now = 7
a:control_tick()
A.eq(a.rcs_disabled, false, "RCS enable flag applied")
A.eq(a.motor_cache.rcs_sb > 0, true, "RCS restored after second toggle")
