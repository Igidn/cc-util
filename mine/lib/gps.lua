-- GPS wrapper for ComputerCraft. Provides locate() with timeout and
-- facing detection via movement delta.
local util = require("lib.util")
local M = {}

local DEFAULT_TIMEOUT = 2
local MOVE_TIMEOUT = 4

--- Try to get position from GPS.
-- @param timeout seconds to wait for GPS response
-- @return x, y, z or nil, error
function M.locate(timeout)
  timeout = timeout or DEFAULT_TIMEOUT
  if not gps then return nil, "gps API not available" end
  local x, y, z = gps.locate(timeout)
  if not x then return nil, "gps locate timeout" end
  return x, y, z
end

--- Determine facing by moving one block forward and measuring delta.
-- Requires GPS to be working and the block ahead to be free.
-- Restores original position after measurement.
-- @param hal hardware abstraction layer with move/inspect
-- @return facing (0=north, 1=east, 2=south, 3=west) or nil, error
function M.detectFacing(hal)
  -- Check if forward is passable
  local data = hal.inspect()
  if data and data.name and data.name ~= "minecraft:air" and
     data.name ~= "minecraft:cave_air" and
     data.name ~= "minecraft:void_air" then
    return nil, "blocked ahead"
  end

  -- Get initial position
  local x1, y1, z1 = M.locate()
  if not x1 then return nil, "gps locate failed (initial)" end

  -- Move forward
  local ok, err = hal.move("forward")
  if not ok then return nil, "move forward failed: " .. tostring(err) end

  -- Get new position
  local x2, y2, z2 = M.locate()
  if not x2 then
    -- Try to move back
    hal.move("back")
    return nil, "gps locate failed (after move)"
  end

  -- Move back to original position
  hal.move("back")

  -- Calculate facing from delta
  local dx = x2 - x1
  local dz = z2 - z1

  if dx == 1 and dz == 0 then return 1 end  -- east
  if dx == -1 and dz == 0 then return 3 end -- west
  if dx == 0 and dz == 1 then return 2 end  -- south
  if dx == 0 and dz == -1 then return 0 end -- north

  return nil, "could not determine facing from GPS delta"
end

--- Sync pose with GPS. Updates x, y, z from GPS, optionally detects facing.
-- @param pose pose table to update (mutated)
-- @param hal hardware abstraction layer
-- @param detectFacing whether to detect facing via movement
-- @return true on success, or nil, error
function M.syncPose(pose, hal, detectFacing)
  local x, y, z = M.locate()
  if not x then return nil, "gps locate failed" end

  pose.x = math.floor(x + 0.5)
  pose.y = math.floor(y + 0.5)
  pose.z = math.floor(z + 0.5)

  if detectFacing then
    local facing, err = M.detectFacing(hal)
    if facing then
      pose.f = facing
    else
      -- Assume the turtle is placed facing north (f=0).
      -- Facing detection requires moving forward one block, which fails
      -- if there's a block ahead. Default to north so the turtle can still
      -- operate; it can correct facing later if needed.
      pose.f = 0
      util.log("gps: facing detection failed (" .. tostring(err) .. "), assuming north (f=0)")
    end
  end

  return true
end

--- Check if GPS is available (modem + satellites in range).
-- @return true if GPS works, false otherwise
function M.available(timeout)
  local _, err = M.locate(timeout or 1)
  return err == nil
end

return M