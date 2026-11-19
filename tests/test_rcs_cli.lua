package.path = "src/?.lua;" .. package.path
local A = dofile("tests/assert.lua")

local old_fs, old_shell, old_print = _G.fs, _G.shell, _G.print
local old_queue = os.queueEvent
local present, body, messages, events = false, nil, {}, {}
_G.fs = {
  getDir=function() return "" end,
  combine=function(left,right) return left == "" and right or left.."/"..right end,
  exists=function(path) return present end,
  delete=function(path) present,body=false,nil end,
  open=function(path,mode)
    if mode ~= "w" then return nil end
    return {write=function(value) body=value;present=true end,close=function() end}
  end,
}
_G.shell = {getRunningProgram=function() return "rcs.lua" end}
_G.print = function(message) messages[#messages+1]=message end
os.queueEvent = function(event) events[#events+1]=event end

dofile("programs/rcs.lua")
A.eq(present,true,"first run creates disable flag")
A.eq(messages[1],"RCS thrusters disabled","disable message")
A.eq(events[1],"autopilot_rcs_changed","disable event")
dofile("programs/rcs.lua")
A.eq(present,false,"second run removes disable flag")
A.eq(messages[2],"RCS thrusters enabled","enable message")
A.eq(events[2],"autopilot_rcs_changed","enable event")

_G.fs, _G.shell, _G.print = old_fs, old_shell, old_print
os.queueEvent = old_queue
