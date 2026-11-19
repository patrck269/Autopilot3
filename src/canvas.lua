local M = {}
local BLIT_HEX = "0123456789abcdef"
local blit_of = {}
local FALLBACK = { white = 1, black = 32768 }

local function blit_char(color)
  local known = blit_of[color]
  if known ~= nil then return known end
  local bit = 1
  for i = 1, 16 do
    if color == bit then
      known = BLIT_HEX:sub(i, i)
      blit_of[color] = known
      return known
    end
    bit = bit * 2
  end
  blit_of[color] = "f"
  return "f"
end

function M.new(w, h, palette)
  palette = palette or _G.colors or FALLBACK
  local rows = {}
  local fg = blit_char(palette.white or FALLBACK.white)
  local bg = blit_char(palette.black or FALLBACK.black)
  for y = 1, h do
    local text, fore, back = {}, {}, {}
    for x = 1, w do
      text[x] = " "
      fore[x] = fg
      back[x] = bg
    end
    rows[y] = { text = text, fg = fore, bg = back }
  end
  return { w = w, h = h, rows = rows, colors = palette }
end

function M.paint(c, x, y, text, fg, bg)
  local row = c.rows[y]
  if row == nil or text == nil or text == "" then return end
  local fore = blit_char(fg)
  local back = blit_char(bg)
  for i = 1, #text do
    local col = x + i - 1
    if col >= 1 and col <= c.w then
      row.text[col] = text:sub(i, i)
      row.fg[col] = fore
      row.bg[col] = back
    end
  end
end

function M.flush(cache, name, mon, c)
  local previous = cache[name]
  local same = previous ~= nil and previous.w == c.w and previous.h == c.h
  local lines = {}
  for y = 1, c.h do
    local row = c.rows[y]
    local text = table.concat(row.text)
    local fg = table.concat(row.fg)
    local bg = table.concat(row.bg)
    local old = same and previous.lines[y] or nil
    if old == nil or old.text ~= text or old.fg ~= fg or old.bg ~= bg then
      mon.setCursorPos(1, y)
      if mon.blit ~= nil then
        mon.blit(text, fg, bg)
      else
        mon.setBackgroundColor(c.colors.black or FALLBACK.black)
        mon.setTextColor(c.colors.white or FALLBACK.white)
        mon.write(text)
      end
    end
    lines[y] = { text = text, fg = fg, bg = bg }
  end
  cache[name] = { w = c.w, h = c.h, lines = lines }
end

return M
