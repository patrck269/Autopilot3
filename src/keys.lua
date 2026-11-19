local numeric = require("numeric")
local M = {}
local BOMB_SIZES = { 1, 3, 5, 10, "all" }

local STICK_KEYS = {
  up={"x",1}, down={"x",-1},
  right={"y",1}, left={"y",-1},
  space={"z",1}, leftShift={"z",-1},
}

local FIELDS = {
  y="altitude", b="bearing", v="speed", x="waypoint_x", z="waypoint_z",
}

local function key_name(code, get_name)
  if type(code) == "string" then return code end
  return get_name and get_name(code) or tostring(code)
end

local function stick_action(kb)
  local values = {x=0,y=0,z=0}
  local newest = {x=0,y=0,z=0}
  for name, order in pairs(kb.pressed) do
    local mapping = STICK_KEYS[name]
    if mapping and order > newest[mapping[1]] then
      newest[mapping[1]] = order
      values[mapping[1]] = mapping[2]
    end
  end
  return {type="stick",x=values.x,y=values.y,z=values.z}
end

local function commit(kb)
  local field, value = kb.field, tonumber(kb.buffer)
  kb.field, kb.buffer = nil, ""
  if not numeric.finite(value) then
    return {type="message",message="not a number"}
  end
  if field == "bearing" then value = math.rad(value % 360) end
  return {type=field,value=value}
end

local function cycle_bombs(kb, delta)
  local current = kb.bomb_size or 1
  local index = 1
  for i, size in ipairs(BOMB_SIZES) do if size == current then index=i break end end
  index = (index - 1 + delta) % #BOMB_SIZES + 1
  kb.bomb_size = BOMB_SIZES[index]
  return {type="bomb_size",size=kb.bomb_size}
end

function M.handle(kb, event, a, b, get_name)
  if kb.field ~= nil then
    if event == "char" then
      if type(a)=="string" and a:match("^[0-9%.%-]$") and #kb.buffer < 16 then
        kb.buffer = kb.buffer .. a
      end
      return nil
    end
    if event ~= "key" then return nil end
    local name = key_name(a, get_name)
    if name == "backspace" then
      kb.buffer = kb.buffer:sub(1, #kb.buffer-1)
    elseif name == "enter" or name == "numPadEnter" then
      return commit(kb)
    elseif name == "tab" then
      kb.field, kb.buffer = nil, ""
    end
    return nil
  end

  if event == "key" or event == "key_up" then
    local name = key_name(a, get_name)
    local mapping = STICK_KEYS[name]
    if mapping ~= nil then
      if event == "key" then
        kb.order = kb.order + 1
        kb.pressed[name] = kb.order
      else
        kb.pressed[name] = nil
      end
      return stick_action(kb)
    end
    if event == "key_up" or b == true then return nil end
    if FIELDS[name] ~= nil then
      kb.field, kb.buffer = FIELDS[name], ""
      return nil
    end
    if name == "m" then return {type="mode",mode="manual"} end
    if name == "s" then return {type="mode",mode="semi"} end
    if name == "u" then return {type="mode",mode="auto"} end
    if name == "t" then return {type="mode",mode="standby"} end
    if name == "w" then
      kb.profile = kb.profile == "warp" and "cruise" or "warp"
      return {type="profile",profile=kb.profile}
    end
    if name == "e" then return {type="emergency"} end
    if name == "c" then return {type="clear_emergency"} end
    if name == "o" then return {type="doors",open=true} end
    if name == "p" then return {type="doors",open=false} end
    if name == "f" then return {type="drop"} end
    if name == "leftBracket" then return cycle_bombs(kb, -1) end
    if name == "rightBracket" then return cycle_bombs(kb, 1) end
  end
  return nil
end

return M
