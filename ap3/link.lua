-- Link between the flight loop and the command center, which run side by
-- side on one computer: messages go through the local event queue
-- ("ap3_local"). Message kinds (field ap3): "status" flight -> command,
-- "cmd" command -> flight, "reply" flight -> command.
local M = {}
M.__index = M

function M.new()
  return setmetatable({}, M)
end

local function post(kind, msg)
  msg.ap3 = kind
  os.queueEvent("ap3_local", msg)
end

function M:send_status(msg) post("status", msg) end
function M:send_command(msg) post("cmd", msg) end
function M:reply(msg) post("reply", msg) end

-- Returns kind, message for a link event, else nil.
function M:parse(ev)
  if ev[1] == "ap3_local" and type(ev[2]) == "table" then
    return ev[2].ap3, ev[2]
  end
  return nil
end

return M
