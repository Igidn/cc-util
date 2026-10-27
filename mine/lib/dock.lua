-- Dock re-zero fixture. Uses GPS for absolute position and facing when available,
-- falls back to physical fixture (bumping into walls) when GPS is unavailable.
local util = require("lib.util")
local pose = require("lib.pose")
local gps = require("lib.gps")

local M = {}

local MAX_TRAVEL = 5

local function blockedOrFuel(ok, err)
  if ok then return false end
  if err and tostring(err):lower():find("fuel", 1, true) then
    return "out of fuel"
  end
  return false
end

local function moveUntilBlocked(hal, op, limit)
  for _ = 1, limit do
    local ok, err = hal.move(op)
    if not ok then
      local fuel = blockedOrFuel(ok, err)
      if fuel then return nil, fuel end
      return true
    end
  end
  return nil, "dock fixture not found (moved too far)"
end

--- @param base table pose to assign after the fixture is found
--- @param hal HAL instance
function M.zero(hal, base)
  base = base or pose.new(0, 0, 0, 0)

  -- Try GPS first
  local ok, err = gps.syncPose(base, hal, true)
  if ok then
    return pose.copy(base)
  end

  util.log("dock: GPS zero failed (" .. tostring(err) .. "), falling back to physical fixture")

  -- Fall back to physical fixture
  ok, err = moveUntilBlocked(hal, "down", MAX_TRAVEL)
  if not ok then return nil, err end

  ok, err = moveUntilBlocked(hal, "back", MAX_TRAVEL)
  if not ok then return nil, err end

  local turned, terr = hal.turnLeft()
  if not turned then return nil, terr or "turnLeft failed" end
  ok, err = moveUntilBlocked(hal, "forward", MAX_TRAVEL)
  if not ok then return nil, err end
  turned, terr = hal.turnRight()
  if not turned then return nil, terr or "turnRight failed" end

  return pose.copy(base)
end

return M
