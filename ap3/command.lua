-- Command center: MFDs on the monitors and typed commands on the terminal,
-- talking to the flight loop on this computer over the link.
local util = require("ap3.util")
local checks = require("ap3.checks")
local mfd = require("ap3.mfd")
local pages = require("ap3.pages")
local store = require("ap3.store")
local cmdline = require("ap3.cmdline")

local M = {}

local function paint_errors(P, cfg, errors, warnings)
  local lines = { { "AUTOPILOT 3.0 COMMAND: START-UP CHECK FAILED", colors.red } }
  for _, e in ipairs(errors) do lines[#lines + 1] = { "ERROR: " .. e, colors.red } end
  for _, w in ipairs(warnings) do lines[#lines + 1] = { "WARN:  " .. w, colors.orange } end
  lines[#lines + 1] = { "Checking again when a peripheral is attached.", colors.lightGray }
  local targets = { term }
  for _, name in ipairs(cfg.monitors or {}) do
    if P.isPresent(name) and P.getType(name) == "monitor" then targets[#targets + 1] = P.wrap(name) end
  end
  for _, t in ipairs(targets) do
    if t ~= term and t.setTextScale then t.setTextScale(cfg.monitor_scale) end
    t.setBackgroundColor(colors.black)
    t.clear()
    for i, l in ipairs(lines) do
      t.setCursorPos(1, i)
      t.setTextColor(l[2])
      t.write(l[1])
    end
  end
  term.setTextColor(colors.white)
end

-- opts = { link = link object }
function M.run(cfg, opts)
  local P = peripheral
  local link = opts.link
  local env = { peripheral = P }
  local errors, warnings, names

  local function wait_peripheral()
    local timer = os.startTimer(2)
    while true do
      local ev = os.pullEvent()
      if ev == "peripheral" or ev == "peripheral_detach" or ev == "timer" then break end
    end
    os.cancelTimer(timer)
  end

  while true do
    errors, warnings, names = checks.command(cfg, env)
    if #errors == 0 then break end
    paint_errors(P, cfg, errors, warnings)
    wait_peripheral()
  end

  local mgr
  local function build()
    local displays = {}
    for _, name in ipairs(names) do
      local mon = P.wrap(name)
      mon.setTextScale(cfg.monitor_scale)
      mon.setBackgroundColor(colors.black)
      mon.clear()
      local w, h = mon.getSize()
      displays[#displays + 1] = { name = name, mon = mon, w = w, h = h }
    end
    local saved = mgr and mgr:layout_state() or store.load(cfg.mfd_file)
    mgr = mfd.new(displays, pages.LIST, saved)
  end
  build()

  local st_time = -math.huge
  local seq = 0

  local ctx = {
    st = nil, age = math.huge, now = os.clock(),
    ufc = { text = "" }, arm = {}, reply = nil,
    local_errors = errors, local_warnings = warnings,
  }
  function ctx.send(c, v)
    seq = seq + 1
    link:send_command({ c = c, v = v, seq = seq })
    ctx.reply = "sent " .. c .. ((v ~= nil and type(v) ~= "table") and (" " .. tostring(v)) or "")
    return true
  end

  local prompt = cmdline.prompt()
  local help = false

  local function draw_terminal()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    local function line(y, text, color)
      term.setCursorPos(1, y)
      term.setTextColor(color or colors.white)
      term.write(text:sub(1, w))
    end
    line(1, "AUTOPILOT 3.0 COMMAND CENTER", colors.yellow)
    local st = ctx.st
    local y = 2
    if st and st.s and ctx.age < 3 then
      local s = st.s
      line(2, tostring(st.slug) .. "  mode " .. st.mode, colors.lime)
      line(3, string.format("Y %s -> %s  VS %s", util.fmt(s.y, 1), util.fmt(st.tgt.alt, 0), util.fmt(s.vy, 2)))
      line(4, string.format("HDG %s -> %s  SPD %s -> %s", util.compass(s.hdg), util.compass(st.tgt.brg),
        util.fmt(s.v_fwd, 1), util.fmt(st.tgt.spd, 0)))
      y = 5
      local b = st.bomb
      if b then
        line(5, string.format("Bombs %d/46  salvo %s  doors %s  next %s", b.left, tostring(b.size),
          b.doors_open and "OPEN" or "SHUT", b.reason or "READY"), b.reason and colors.orange or colors.lime)
        y = 6
      end
      if st.mode == "NAV" and st.nav and st.nav.last then
        local l = st.nav.last
        line(y, string.format("NAV %d/%d %s  dist %s  brg %s", l.i, l.n, tostring(st.nav.phase),
          util.fmt(l.d, 0), util.compass(l.brg_to)), colors.cyan)
        y = y + 1
      end
      for _, a in ipairs(st.alerts or {}) do
        if y < h - 2 then line(y, a, colors.red); y = y + 1 end
      end
    elseif st and st.errors then
      line(2, "FLIGHT START-UP CHECK FAILED:", colors.red)
      y = 3
      for _, e in ipairs(st.errors) do
        if y < h - 2 then line(y, e, colors.orange); y = y + 1 end
      end
    else
      line(2, "No flight data", colors.red)
      y = 3
    end
    local warns = {}
    for _, wmsg in ipairs(st and st.warnings or {}) do warns[#warns + 1] = wmsg end
    for _, wmsg in ipairs(warnings) do warns[#warns + 1] = wmsg end
    for _, wmsg in ipairs(warns) do
      if y < h - 2 then line(y, wmsg, colors.orange); y = y + 1 end
    end
    if help then
      for _, hl in ipairs(cmdline.HELP) do
        if y < h - 1 then line(y, hl, colors.lightGray); y = y + 1 end
      end
    end
    line(h - 1, ctx.reply or "type help for commands", colors.lightGray)
    line(h, "> " .. prompt.text, colors.white)
    term.setCursorPos(math.min(w, 3 + #prompt.text), h)
    term.setCursorBlink(true)
  end

  local redraw = os.startTimer(0.2)
  local term_at = 0
  while true do
    local ev = { os.pullEvent() }
    ctx.now = os.clock()
    ctx.age = ctx.now - st_time
    local kind, msg = link:parse(ev)
    if kind == "status" then
      ctx.st = msg
      st_time = ctx.now
      ctx.age = 0
    elseif kind == "reply" then
      ctx.reply = (msg.ok and "" or "REJECTED: ") .. tostring(msg.text)
    elseif ev[1] == "timer" and ev[2] == redraw then
      redraw = os.startTimer(0.2)
      mgr:draw_all(ctx)
      if ctx.now - term_at >= 0.5 then
        term_at = ctx.now
        draw_terminal()
      end
    elseif ev[1] == "monitor_touch" then
      local changed = mgr:touch(ev[2], ev[3], ev[4], ctx)
      if changed == "layout" then store.save(cfg.mfd_file, mgr:layout_state()) end
      if changed then mgr:draw_all(ctx) end
    elseif ev[1] == "monitor_resize" then
      build()
      mgr:draw_all(ctx)
    elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
      local errs, warns, found = checks.command(cfg, env)
      ctx.local_errors, ctx.local_warnings, warnings = errs, warns, warns
      if #found > 0 then
        names = found
        build()
        mgr:draw_all(ctx)
      end
    else
      local line = prompt.handle(ev)
      if line then
        local cmd, err = cmdline.parse(line)
        help = false
        if cmd == "help" then
          help = true
        elseif cmd then
          ctx.send(cmd.c, cmd.v)
        elseif err ~= "" then
          ctx.reply = err
        end
        draw_terminal()
      elseif ev[1] == "char" or ev[1] == "key" or ev[1] == "paste" then
        draw_terminal()
      end
    end
  end
end

return M
