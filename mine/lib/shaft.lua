-- Shaft queue client. Manages mutual exclusion on a station's single shaft.
-- A turtle must acquire the shaft lock before entering the shaft column and
-- release it when leaving. Uses the console's /api/shaft endpoints.
local util = require("lib.util")

local M = {}

local function httpPostJson(url, payloadTable)
  local payload = textutils.serializeJSON(payloadTable)
  local response, err = http.post(url, payload, {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "cc-util/0.1.0",
  })
  if not response then return nil, err or "http.post failed" end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil, ("http %d: %s"):format(code, text) end
  return text
end

local function httpGetText(url)
  local response, err = http.get(url, { ["User-Agent"] = "cc-util/0.1.0" })
  if not response then return nil, err or "http.get failed" end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil, ("http %d from %s"):format(code, url) end
  return text
end

-- Acquire shaft access for this turtle at the given station.
-- Blocks (polls) until granted, or returns nil on rejection/timeout.
-- @param tunnel server base URL
-- @param stationId station id
-- @param turtleId this turtle's id
-- @param purpose string describing why the turtle needs the shaft
-- @return true on granted, nil on failure
function M.acquire(tunnel, stationId, turtleId, purpose)
  purpose = purpose or "transit"

  util.log("shaft: acquiring lock for", stationId, "turtle", turtleId)

  local text, err = httpPostJson(tunnel .. "/api/shaft/" .. stationId .. "/acquire", {
    turtleId = turtleId,
    purpose = purpose,
  })
  if not text then
    util.log("shaft: acquire request failed:", err or "no response")
    return nil
  end
  util.log("shaft: acquire response:", text)
  local data = util.jsonDecode(text)
  if not data then
    util.log("shaft: acquire response malformed")
    return nil
  end

  if data.granted then
    util.log("shaft: granted access to", stationId)
    return true
  end

  if data.queued then
    util.log("shaft: queued at position", data.position, "for", stationId)
    -- Poll status until we become the holder.
    local deadline = (os.epoch and os.epoch("utc") or os.time() * 1000) + 600 * 1000 -- 10 min max
    while true do
      local now = os.epoch and os.epoch("utc") or os.time() * 1000
      if now > deadline then
        util.log("shaft: queue timeout for", stationId)
        return nil
      end
      os.sleep(2)

      local stext, serr = httpGetText(tunnel .. "/api/shaft/" .. stationId .. "/status")
      if stext then
        local sdata = util.jsonDecode(stext)
        if sdata and sdata.lock and sdata.lock.holderTurtleId == turtleId then
          util.log("shaft: promoted to holder for", stationId)
          return true
        end
      end
    end
  end

  if data.rejected then
    util.log("shaft: acquire rejected:", data.reason)
    return nil
  end

  return nil
end

-- Release shaft access. Promotes the next waiter if any.
-- @return true on success
function M.release(tunnel, stationId, turtleId)
  local text, err = httpPostJson(tunnel .. "/api/shaft/" .. stationId .. "/release", {
    turtleId = turtleId,
  })
  if not text then
    util.log("shaft: release request failed:", err or "no response")
    return false
  end
  local data = util.jsonDecode(text)
  if not data or not data.ok then
    util.log("shaft: release failed:", data and data.reason or "unknown")
    return false
  end
  if data.next then
    util.log("shaft: released, next holder is", data.next)
  else
    util.log("shaft: released, queue empty")
  end
  return true
end

return M
