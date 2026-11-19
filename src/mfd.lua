local canvas = require("canvas")
local bombs = require("bombs")
local M = {}

M.PAGES = { "FLT", "BOMB", "NAV", "ENG", "SYS" }

local DEFAULT_COLORS = {
  white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32,
  pink=64, gray=128, lightGray=256, cyan=512, purple=1024,
  blue=2048, brown=4096, green=8192, red=16384, black=32768,
}

local function page_known(page)
  for _, known in ipairs(M.PAGES) do
    if page == known then return true end
  end
  return false
end

function M.tabs(w, h)
  local tabs = {}
  local width = math.floor((w - 4) / 5)
  if width >= 4 then
    local y = h - 2
    for i, page in ipairs(M.PAGES) do
      tabs[#tabs + 1] = { x=(i-1)*(width+1)+1, y=y, w=width, h=3,
        label=page, page=page, color="blue" }
    end
  else
    local first_width = math.max(1, math.floor((w - 2) / 3))
    local second_width = math.max(1, math.floor((w - 1) / 2))
    for i = 1, 3 do
      local page = M.PAGES[i]
      tabs[#tabs + 1] = { x=(i-1)*(first_width+1)+1, y=h-5,
        w=first_width, h=3, label=page, page=page, color="blue" }
    end
    for i = 1, 2 do
      local page = M.PAGES[i+3]
      tabs[#tabs + 1] = { x=(i-1)*(second_width+1)+1, y=h-2,
        w=second_width, h=3, label=page, page=page, color="blue" }
    end
  end
  return tabs
end

function M.assign(names, saved)
  local sorted = {}
  for i, name in ipairs(names) do sorted[i] = name end
  table.sort(sorted)
  local assigned, shown = {}, {}
  for _, name in ipairs(sorted) do
    local page = saved and saved[name] or nil
    if page_known(page) then
      assigned[name] = page
      shown[page] = true
    end
  end
  for index, name in ipairs(sorted) do
    if assigned[name] == nil then
      local page
      for _, candidate in ipairs(M.PAGES) do
        if not shown[candidate] then page = candidate break end
      end
      page = page or M.PAGES[(index - 1) % #M.PAGES + 1]
      assigned[name] = page
      shown[page] = true
    end
  end
  return assigned
end

function M.select(map, name, page)
  if not page_known(page) or map[name] == nil then return false end
  for other, current in pairs(map) do
    if other ~= name and current == page then
      map[other], map[name] = map[name], page
      return true
    end
  end
  map[name] = page
  return true
end

function M.flow(specs, x0, y0, xmax)
  local buttons, x, y = {}, x0, y0
  for _, spec in ipairs(specs) do
    local width = #spec.label + 2
    if x ~= x0 and x + width - 1 > xmax then
      x = x0
      y = y + 4
    end
    buttons[#buttons + 1] = {
      x=x, y=y, w=width, h=3, label=spec.label,
      action=spec.action, color=spec.color or "blue",
    }
    x = x + width + 1
  end
  return buttons
end

local function append(target, values)
  for _, value in ipairs(values) do target[#target + 1] = value end
end

local function button(label, action, color)
  return { label=label, action=action, color=color }
end

function M.layout(page, w, h, view)
  local tabs = M.tabs(w, h)
  local tab_top = h + 1
  for _, tab in ipairs(tabs) do tab_top = math.min(tab_top, tab.y) end
  local layout = { page=page, w=w, h=h, tabs=tabs, buttons={}, content_bottom=tab_top-1 }

  if page == "FLT" then
    local specs = {}
    for _, item in ipairs({{"MAN","manual"},{"SEMI","semi"},{"AUTO","auto"},{"STBY","standby"}}) do
      specs[#specs+1] = button(item[1], {type="mode",mode=item[2]},
        view.mode == item[2] and "lime" or "blue")
    end
    for _, item in ipairs({{"ALT-10","alt_nudge",-10},{"ALT+10","alt_nudge",10},
      {"HDG-15","hdg_nudge",-15},{"HDG-5","hdg_nudge",-5},
      {"HDG+5","hdg_nudge",5},{"HDG+15","hdg_nudge",15},
      {"SPD-5","spd_nudge",-5},{"SPD-1","spd_nudge",-1},
      {"SPD+1","spd_nudge",1},{"SPD+5","spd_nudge",5}}) do
      specs[#specs+1] = button(item[1], {type=item[2],delta=item[3]})
    end
    layout.buttons = M.flow(specs, 1, 7, w)
  elseif page == "BOMB" then
    local content_height = layout.content_bottom - 1
    local controls_x, controls_y, controls_max
    if content_height >= 25 then
      layout.bay = { orientation="vertical", x=1, y=2 }
      controls_x, controls_y, controls_max = 9, 2, w
    elseif w >= 71 then
      layout.bay = { orientation="horizontal", x=2, y=2 }
      controls_x, controls_y, controls_max = 1, 6, w
    else
      layout.bay = { orientation="small", x=1, y=2 }
      controls_x, controls_y, controls_max = 1, 4, w
    end
    local specs = {}
    for _, size in ipairs(view.bomb_sizes or {1,3,5,10,"all"}) do
      local label = size == "all" and "ALL" or tostring(size)
      specs[#specs+1] = button(label, {type="bomb_size",size=size},
        view.bombs.size == size and "lime" or "blue")
    end
    specs[#specs+1] = button(view.bombs.doors_open and "CLOSE DOORS" or "OPEN DOORS",
      {type="doors",open=not view.bombs.doors_open})
    local preview_count = view.bomb_preview and #view.bomb_preview or 0
    specs[#specs+1] = button("DROP " .. preview_count, {type="drop"},
      view.bomb_reason == nil and "red" or "gray")
    specs[#specs+1] = button("RELOAD", {type="confirm",action="reload"})
    layout.buttons = M.flow(specs, controls_x, controls_y, controls_max)
    layout.status_x = controls_x
    local max_y = controls_y
    for _, control in ipairs(layout.buttons) do max_y = math.max(max_y, control.y + control.h - 1) end
    layout.status_y = max_y + 1
  elseif page == "NAV" then
    layout.buttons = M.flow({
      button("CRUISE", {type="profile",profile="cruise"}, view.profile=="cruise" and "lime" or "blue"),
      button("WARP", {type="profile",profile="warp"}, view.profile=="warp" and "lime" or "blue"),
      button("ENGAGE AUTO", {type="mode",mode="auto"}),
    }, 1, 9, w)
  elseif page == "SYS" then
    layout.buttons = M.flow({
      button("EMERG STOP", {type="confirm",action="emergency"}, "red"),
      button("CLEAR EMERG", {type="clear_emergency"}),
    }, 1, math.min(layout.content_bottom-3, 10), w)
  end
  return layout
end

local function inside(control, x, y)
  return x >= control.x and x < control.x + control.w
    and y >= control.y and y < control.y + control.h
end

function M.hit(layout, tabs, x, y)
  for _, control in ipairs(layout.buttons or {}) do
    if inside(control, x, y) then return control.action end
  end
  for _, tab in ipairs(tabs or layout.tabs or {}) do
    if inside(tab, x, y) then return {type="page",page=tab.page} end
  end
  return nil
end

local function number(value, decimals)
  if type(value) ~= "number" then return "--" end
  return string.format("%." .. (decimals or 1) .. "f", value)
end

local function degrees(value)
  if type(value) ~= "number" then return "--" end
  return string.format("%.0f", (math.deg(value) % 360 + 360) % 360)
end

local function color(colors, name)
  return colors[name] or DEFAULT_COLORS[name]
end

local function paint(c, x, y, text, fg, bg)
  local colors = c.colors or DEFAULT_COLORS
  canvas.paint(c, x, y, text, color(colors, fg or "white"), color(colors, bg or "black"))
end

local function draw_button(c, control, view)
  local label = control.label
  local confirm = view.confirm
  if control.action and control.action.type == "confirm" and confirm ~= nil
      and confirm.action == control.action.action and (confirm.until_time or confirm["until"] or 0) >= (view.now or 0) then
    label = "CONFIRM?"
  end
  if #label > control.w then label = label:sub(1, control.w) end
  local left = math.floor((control.w - #label) / 2)
  for dy = 0, control.h - 1 do
    local text = string.rep(" ", control.w)
    if dy == math.floor(control.h / 2) then
      text = string.rep(" ", left) .. label .. string.rep(" ", control.w - left - #label)
    end
    paint(c, control.x, control.y + dy, text, "black", control.color)
  end
end

local function draw_banner(c, view)
  local mode = string.upper(view.mode or "standby")
  local emerg = view.emergency and " EMERG" or ""
  local left = view.bombs_left or 0
  local alert = view.alert or ""
  local text = string.format("%s%s ALT %s HDG %s SPD %s BOMBS %d/46 %s",
    mode, emerg, number(view.y, 1), degrees(view.heading), number(view.forward_speed, 1), left, alert)
  if #text < c.w then text = text .. string.rep(" ", c.w - #text) end
  local danger = view.emergency or (view.missing and #view.missing > 0) or view.control_error
  paint(c, 1, 1, text:sub(1, c.w), "black", danger and "red" or "lightBlue")
end

local function preview_set(view)
  local result = {}
  for _, id in ipairs(view.bomb_preview or {}) do result[id] = true end
  return result
end

local function draw_bay(c, layout, view)
  local bay, preview = layout.bay, preview_set(view)
  if bay.orientation == "small" then
    paint(c, bay.x, bay.y, "Bombs " .. (view.bombs_left or 0) .. "/46 (monitor too small for bay map)")
    return
  end
  local function cell(id)
    local bg = "lime"
    if not view.bomb_relays[id] then bg = "red"
    elseif view.bombs.used[id] then bg = "gray"
    elseif preview[id] then bg = "yellow" end
    return string.format("%02d", id), bg
  end
  if bay.orientation == "vertical" then
    paint(c, bay.x, bay.y, "BOW")
    for row = 1, 23 do
      local port = row <= 21 and 13 + row or (row == 22 and 13 or 35)
      local starboard = 59 - row
      local ptext, pcolor = cell(port)
      local stext, scolor = cell(starboard)
      paint(c, bay.x, bay.y + row, ptext, "black", pcolor)
      paint(c, bay.x + 3, bay.y + row, stext, "black", scolor)
    end
    paint(c, bay.x, bay.y + 24, "STERN")
  else
    paint(c, 1, bay.y, "P")
    paint(c, 1, bay.y + 1, "S")
    for row = 1, 23 do
      local port = row <= 21 and 13 + row or (row == 22 and 13 or 35)
      local starboard = 59 - row
      local ptext, pcolor = cell(port)
      local stext, scolor = cell(starboard)
      local x = bay.x + (row - 1) * 3
      paint(c, x, bay.y, ptext, "black", pcolor)
      paint(c, x, bay.y + 1, stext, "black", scolor)
    end
  end
end

local function compass(heading, width)
  local ticks = {}
  for i = 1, width do ticks[i] = "-" end
  local turns = (heading or 0) / (2 * math.pi)
  turns = turns - math.floor(turns)
  local index = math.floor(turns * width) + 1
  if index > width then index = 1 end
  ticks[index] = "|"
  return table.concat(ticks)
end

function M.draw(c, page, view, layout)
  draw_banner(c, view)
  if page == "FLT" then
    paint(c, 1, 2, "ALT "..number(view.y).." -> "..number(view.alt_target).."  VS "..number(view.vy))
    paint(c, 1, 3, "HDG "..degrees(view.heading).." -> "..degrees(view.bearing_target).."  YAW "..number(math.deg(view.yaw_rate or 0)))
    paint(c, 1, 4, "SPD "..number(view.forward_speed).." -> "..number(view.speed_target).." (ramp "..number(view.ramp)..")  SIDE "..number(view.side_speed))
    paint(c, 1, 5, "PITCH "..number(math.deg(view.pitch or 0)).."  ROLL "..number(math.deg(view.roll or 0)))
  elseif page == "BOMB" then
    draw_bay(c, layout, view)
    local y = layout.status_y
    paint(c, layout.status_x, y, "Loaded "..(view.bombs_left or 0).."/46")
    local door = view.bombs.doors_open and ("Doors OPEN "..math.max(0, math.floor((view.now or 0)-(view.bombs.opened_at or view.now or 0))).."s") or "Doors CLOSED"
    paint(c, layout.status_x, y+1, door)
    paint(c, layout.status_x, y+2, "Next drop: "..(view.bomb_reason or "READY"))
    paint(c, layout.status_x, y+3, "Last: "..(view.last_message or ""))
  elseif page == "NAV" then
    paint(c, 1, 2, "WPT X "..number(view.waypoint_x).." Z "..number(view.waypoint_z))
    paint(c, 1, 3, "DIST "..number(view.distance).."  BRG "..degrees(view.waypoint_bearing))
    paint(c, 1, 4, "PHASE "..tostring(view.phase or "-").."  PROFILE "..tostring(view.profile or "-"))
    local eta = "n/a"
    if type(view.distance)=="number" and math.abs(view.forward_speed or 0)>0 then eta=number(view.distance/math.abs(view.forward_speed),0).."s" end
    paint(c, 1, 5, "ETA "..eta)
    paint(c, 1, 6, compass(view.heading, math.max(1,c.w-2)))
    paint(c, 1, 7, "Set X/Z on computer-12 keyboard")
  elseif page == "ENG" then
    local rows = {
      {"elev_pb","E7 PB elev"},{"elev_sb","E2 SB elev"},{"elev_ps","E5 PS elev"},{"elev_ss","E3 SS elev"},
      {"rcs_pb","R6 PB rcs"},{"rcs_sb","R1 SB rcs"},{"rcs_ps","R4 PS rcs"},{"rcs_ss","R0 SS rcs"},
      {"push_port","L8 port push"},{"push_stbd","S9 stbd push"},
    }
    for index, item in ipairs(rows) do
      local state = view.motor_states[item[1]] or {}
      local status = state.present and "ok" or "MISSING"
      paint(c, 1, index+1, string.format("%-13s %s  %s", item[2], number(state.rpm,0), status),
        state.present and "white" or "red")
    end
    local hover = view.hover_rpm or 0
    paint(c, 1, 12, "HOVER "..number(hover,0).."  TRIM P "..number((view.trim_pitch or 0)*hover,0).." R "..number((view.trim_roll or 0)*hover,0).."  PUSH-I "..number(view.push_i,0))
  elseif page == "SYS" then
    paint(c, 1, 2, "Missing peripherals:")
    local y = 3
    if not view.missing or #view.missing == 0 then
      paint(c, 1, y, "none")
      y = y + 1
    else
      for _, name in ipairs(view.missing) do paint(c, 1, y, name, "red"); y=y+1 end
    end
    paint(c, 1, y, view.rcs_disabled and "RCS DISABLED (helm control)" or "RCS ENABLED")
    y = y + 1
    paint(c, 1, y, "Monitors "..tostring(view.monitor_count or 0)); y=y+1
    local first = math.max(1, #(view.logs or {}) - 5)
    for index = first, #(view.logs or {}) do paint(c, 1, y, view.logs[index]); y=y+1 end
  end
  for _, control in ipairs(layout.buttons or {}) do draw_button(c, control, view) end
  for _, tab in ipairs(layout.tabs or {}) do
    local copy = {x=tab.x,y=tab.y,w=tab.w,h=tab.h,label=tab.label,
      action={type="page",page=tab.page},color=tab.page==page and "lime" or "blue"}
    draw_button(c, copy, view)
  end
end

return M
