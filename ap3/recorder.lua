-- Flight recorder: 'rec on' writes one CSV row every rec.every control
-- steps to rec_file (overwritten), for analysis on the host with
-- tools/rec_analyze.py. It stops itself before the disk fills.
local actuators = require("ap3.actuators")

local M = {}
M.__index = M

M.HEADER = "t,mode,x,y,z,vx,vy,vz,hdg,pitch,roll,yaw_rate,tgt_alt,tgt_brg,spd_tgt,v_ref,"
  .. "alt_phase,hdg_active,sway_active,nav_phase,lbp,lbs,lsp,lss,rbp,rbs,rsp,rss,pp,ps"

function M.new(cfg)
  return setmetatable({ cfg = cfg, h = nil, rows = 0, full = false, n = 0 }, M)
end

-- Start a new recording. Returns ok, message.
function M:start()
  if self.h then self.h.close() end
  local h = fs.open(self.cfg.rec_file, "w")
  if not h then
    self.h = nil
    return false, "cannot open " .. self.cfg.rec_file
  end
  h.writeLine(M.HEADER)
  self.h, self.rows, self.full, self.n = h, 0, false, 0
  return true, "recording to " .. self.cfg.rec_file
end

function M:stop()
  if self.h then
    self.h.flush()
    self.h.close()
    self.h = nil
  end
end

local function num(fmt, v)
  if type(v) ~= "number" or v ~= v then return "" end
  return string.format(fmt, v)
end

local function flag(v)
  if v == nil then return "" end
  return v and "1" or "0"
end

-- One control step: write a row every rec.every steps while recording.
function M:sample(now, s, ap, bank)
  if not self.h then return end
  self.n = self.n + 1
  if self.n % self.cfg.rec.every ~= 0 then return end
  local row = {
    num("%.2f", now), ap.mode,
    num("%.3f", s.x), num("%.3f", s.y), num("%.3f", s.z),
    num("%.3f", s.vx), num("%.3f", s.vy), num("%.3f", s.vz),
    num("%.2f", s.hdg), num("%.2f", s.pitch), num("%.2f", s.roll), num("%.2f", s.yaw_rate),
    num("%.2f", ap.tgt.alt), num("%.2f", ap.tgt.brg), num("%.2f", ap.spd.target), num("%.2f", ap.spd.v_ref),
    ap.alt.phase or "", flag(ap.hdg.active), flag(ap.hdg.sway_active), ap.nav.phase or "",
  }
  for _, id in ipairs(actuators.ORDER) do row[#row + 1] = num("%.0f", bank:applied(id)) end
  self.h.writeLine(table.concat(row, ","))
  self.rows = self.rows + 1
  if self.rows % 10 == 0 then self.h.flush() end
  if self.rows % 50 == 0 and fs.getFreeSpace("/") < self.cfg.rec.min_free then
    self:stop()
    self.full = true
  end
end

return M
