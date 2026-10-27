-- Hauler. Two jobs:
--  (A) Deliver player-requested ores/blocks up from underground storage to
--      the surface depot chest.
--  (B) Move items up automatically when storage reaches 3.5/4 (28/32) filled.
--  (C) Deliver fuel (lava) down to the miners' refueling chest at Y10.
-- Uses the shaft queue for all shaft traversals.
local util = require("lib.util")
local pose = require("lib.pose")
local nav = require("lib.nav")
local hal = require("lib.hal")
local gps = require("lib.gps")
local shaft = require("lib.shaft")

local M = {}

local TARGET_Y = 10
local STORAGE_THRESHOLD_HIGH = 28 -- 3.5/4 of 32 -> hauler starts moving items up
local STORAGE_THRESHOLD_LOW = 24  -- 3/4 of 32 -> console notifies player to setup surface depot
local EVACUATE_TARGET_FILL = 12   -- evacuate until fill drops to ~3/8 (12/32)

-- Hauler wait position inside the station (relative to station anchor).
-- The hauler parks here between jobs so it's not blocking the shaft.
local HAULER_WAIT_POS = { x = 2, y = 10, z = 2, f = 0 }

----------------------------------------------------------------------
-- GPS
----------------------------------------------------------------------

local function syncGps()
  local initPose = { x = 0, y = 0, z = 0, f = 0 }
  local ok, err = gps.syncPose(initPose, hal, true)
  if ok then
    util.log("hauler: GPS synced")
    return true
  end
  util.log("hauler: GPS unavailable:", err or "unknown")
  return false
end

----------------------------------------------------------------------
-- Navigation helpers
----------------------------------------------------------------------

-- Descend the shaft to Y10. Returns true on success.
local function descendToY10(navInstance)
  local currentY = navInstance.pose.y
  if currentY > TARGET_Y then
    local depth = currentY - TARGET_Y
    for i = 1, depth do
      local ok, err = nav.down(navInstance, 1)
      if not ok then
        util.log("hauler: descend failed at Y", navInstance.pose.y, ":", err or "unknown")
        return false
      end
    end
  end
  util.log("hauler: at Y", navInstance.pose.y)
  return true
end

-- Ascend the shaft to surface.
local function ascendToSurface(navInstance, surfaceY)
  local currentY = navInstance.pose.y
  if currentY < surfaceY then
    local height = surfaceY - currentY
    for i = 1, height do
      local ok, err = nav.up(navInstance, 1)
      if not ok then
        util.log("hauler: ascend failed at Y", navInstance.pose.y, ":", err or "unknown")
        return false
      end
    end
  end
  util.log("hauler: at surface Y", navInstance.pose.y)
  return true
end

----------------------------------------------------------------------
-- Item requests
----------------------------------------------------------------------

-- Poll the console for pending item requests.
-- @return request table or nil
local function pollRequest(tunnel, stationId)
  local response, err = http.get(tunnel .. "/api/requests?stationId=" .. stationId .. "&status=pending", {
    ["User-Agent"] = "cc-util/0.1.0",
  })
  if not response then return nil end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil end
  local data = util.jsonDecode(text)
  if not data or not data.requests or #data.requests == 0 then return nil end
  return data.requests[1]
end

-- Mark a request as assigned to this hauler.
local function assignRequest(tunnel, requestId, turtleId)
  local payload = textutils.serializeJSON({ haulerId = turtleId })
  local response, err = http.post(tunnel .. "/api/requests/" .. requestId .. "/assign", payload, {
    ["Content-Type"] = "application/json",
  })
  if not response then return false end
  response.close()
  return true
end

-- Mark a request as delivered.
local function deliverRequest(tunnel, requestId)
  local response, err = http.post(tunnel .. "/api/requests/" .. requestId .. "/deliver", "", {
    ["Content-Type"] = "application/json",
  })
  if not response then return false end
  response.close()
  return true
end

----------------------------------------------------------------------
-- Storage chest operations
----------------------------------------------------------------------

-- Find a storage chest containing the requested item.
-- Returns chest id and slot, or nil.
local function findItemInStorage(itemName, count)
  -- Inspect adjacent chests for the requested item.
  -- This is a simplified version; full implementation scans known chest positions.
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and item.name == itemName then
      return slot
    end
  end
  return nil
end

-- Suck items from an adjacent chest into inventory.
local function suckFromChest(count)
  local sucked = 0
  for _ = 1, count do
    if not hal.suckUp() then break end
    sucked = sucked + 1
  end
  return sucked
end

-- Drop items into an adjacent chest.
local function dropIntoChest()
  local dropped = 0
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item then
      hal.select(slot)
      if hal.dropDown() then
        dropped = dropped + 1
      end
    end
  end
  return dropped
end

-- Get station storage fill info from console.
-- Returns { filled = N, total = 32 } or nil on failure.
local function getStationFill(tunnel, stationId)
  local response, err = http.get(tunnel .. "/api/chests?stationId=" .. stationId, {
    ["User-Agent"] = "cc-util/0.1.0",
  })
  if not response then return nil end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil end
  local data = util.jsonDecode(text)
  if not data or type(data.chests) ~= "table" then return nil end
  local filled = 0
  local total = 0
  for _, chest in ipairs(data.chests) do
    if chest.kind == "storage" then
      total = total + 1
      if chest.fillPercent and chest.fillPercent > 0 then
        filled = filled + 1
      end
    end
  end
  return { filled = filled, total = total }
end

-- Evacuate items from storage chests up to surface depot.
-- Moves items from the least-full storage chests first to reduce fill count.
-- Stops when filled chests drop to EVACUATE_TARGET_FILL.
local function evacuateStorage(tunnel, stationId, turtleId, navInstance, surfaceY, maxTrips)
  util.log("hauler: starting storage evacuation, maxTrips", maxTrips)
  local trips = 0
  while trips < maxTrips do
    local fill = getStationFill(tunnel, stationId)
    if not fill then
      util.log("hauler: could not read station fill, stopping evacuation")
      return false
    end
    if fill.filled <= EVACUATE_TARGET_FILL then
      util.log(("hauler: evacuation complete, %d/%d chests filled"):format(fill.filled, fill.total))
      return true
    end

    -- Acquire shaft, descend, collect items from a storage chest, ascend, deposit at depot
    if not shaft.acquire(tunnel, stationId, turtleId, "evacuation") then
      util.log("hauler: could not acquire shaft for evacuation")
      return false
    end

    if not descendToY10(navInstance) then
      shaft.release(tunnel, stationId, turtleId)
      return false
    end

    -- Collect items from adjacent storage chest
    local collected = 0
    for _ = 1, 64 do
      local got = suckFromChest(64 - collected)
      collected = collected + got
      if got == 0 then break end
    end

    if collected == 0 then
      -- No items available from this chest, release and try again
      shaft.release(tunnel, stationId, turtleId)
      util.log("hauler: no items to collect, stopping evacuation")
      return true
    end

    util.log("hauler: collected", collected, "items for evacuation")

    if not ascendToSurface(navInstance, surfaceY) then
      shaft.release(tunnel, stationId, turtleId)
      return false
    end

    local dropped = dropIntoChest()
    util.log("hauler: dropped", dropped, "items into depot chest")

    shaft.release(tunnel, stationId, turtleId)
    trips = trips + 1

    -- Return to wait position for next cycle
    parkAtWaitPosition(navInstance, surfaceY)
  end

  util.log("hauler: evacuation reached maxTrips", maxTrips)
  return true
end

----------------------------------------------------------------------
-- Fuel delivery (down)
----------------------------------------------------------------------

-- Deliver lava fuel to the refueling chest at Y10.
local function deliverFuelDown(tunnel, stationId, turtleId, navInstance, surfaceY)
  util.log("hauler: delivering fuel down")
  if not shaft.acquire(tunnel, stationId, turtleId, "fuel_delivery") then
    util.log("hauler: could not acquire shaft for fuel delivery")
    return false
  end

  if not descendToY10(navInstance) then
    shaft.release(tunnel, stationId, turtleId)
    return false
  end

  -- Drop lava buckets into the refueling chest (below the turtle)
  local dropped = dropIntoChest()
  util.log("hauler: dropped", dropped, "fuel items into refuel chest")

  if not ascendToSurface(navInstance, surfaceY) then
    shaft.release(tunnel, stationId, turtleId)
    return false
  end

  shaft.release(tunnel, stationId, turtleId)
  return true
end

----------------------------------------------------------------------
-- Item delivery up (player request or threshold evacuation)
----------------------------------------------------------------------

-- Deliver items from underground storage up to surface depot.
local function deliverItemsUp(tunnel, stationId, turtleId, navInstance, surfaceY, itemName, count)
  util.log("hauler: delivering items up", itemName, count)
  if not shaft.acquire(tunnel, stationId, turtleId, "item_delivery") then
    util.log("hauler: could not acquire shaft for item delivery")
    return false
  end

  if not descendToY10(navInstance) then
    shaft.release(tunnel, stationId, turtleId)
    return false
  end

  -- Collect requested items from storage chests
  local collected = 0
  -- Simplified: suck from adjacent chest
  while collected < count do
    local got = suckFromChest(count - collected)
    collected = collected + got
    if got == 0 then break end -- no more items available
  end

  util.log("hauler: collected", collected, "items")

  if not ascendToSurface(navInstance, surfaceY) then
    shaft.release(tunnel, stationId, turtleId)
    return false
  end

  -- Drop into surface depot chest (below the turtle at surface)
  local dropped = dropIntoChest()
  util.log("hauler: dropped", dropped, "items into depot chest")

  shaft.release(tunnel, stationId, turtleId)
  return true
end

----------------------------------------------------------------------
-- Main run loop
----------------------------------------------------------------------

function M.run(id, bus)
  local tunnel = bus.serverUrl
  if not tunnel then
    util.log("hauler: no server URL, cannot operate")
    return nil, "no server URL"
  end

  local stationId = bus.station and bus.station.id or "s0"
  local turtleId = id
  local surfaceY = bus.pose and bus.pose.y or 10

  -- GPS sync
  syncGps()

  -- Create nav instance
  local navInstance = nav.new(hal, nil, 0, bus.pose or { x = 0, y = 0, z = 0, f = 0 }, true)

  -- Park at hauler wait position inside the station
  local function parkAtWaitPosition(navInstance, surfaceY)
    -- Move to wait position (simplified: direct move)
    local wx, wy, wz, wf = HAULER_WAIT_POS.x, HAULER_WAIT_POS.y, HAULER_WAIT_POS.z, HAULER_WAIT_POS.f
    nav.face(navInstance, wf)
    -- Move in X then Z (simplified pathfinding)
    local dx = wx - navInstance.pose.x
    local dz = wz - navInstance.pose.z
    if dx > 0 then nav.face(navInstance, 1) end  -- east
    if dx < 0 then nav.face(navInstance, 3) end  -- west
    for _ = 1, math.abs(dx) do nav.forward(navInstance, 1) end
    if dz > 0 then nav.face(navInstance, 2) end  -- south
    if dz < 0 then nav.face(navInstance, 0) end  -- north
    for _ = 1, math.abs(dz) do nav.forward(navInstance, 1) end
    -- Adjust Y
    local dy = wy - navInstance.pose.y
    if dy > 0 then
      for _ = 1, dy do nav.up(navInstance, 1) end
    elseif dy < 0 then
      for _ = 1, math.abs(dy) do nav.down(navInstance, 1) end
    end
    util.log("hauler: parked at wait position", wx, wy, wz)
  end

  -- Initial park
  parkAtWaitPosition(navInstance, surfaceY)

  util.log("hauler: running, station", stationId)

  while true do
    bus.role = "hauler"
    bus.state = "waiting"

    -- Check for pending player requests
    local request = pollRequest(tunnel, stationId)
    if request then
      bus.state = "delivering"
      util.log("hauler: got request", request.itemName, request.count)

      local assigned = assignRequest(tunnel, request.id, turtleId)
      if not assigned then
        util.log("hauler: failed to assign request", request.id)
      else
        local ok = deliverItemsUp(tunnel, stationId, turtleId, navInstance, surfaceY, request.itemName, request.count)
        if ok then
          deliverRequest(tunnel, request.id)
          util.log("hauler: request delivered", request.id)
        else
          util.log("hauler: request delivery failed", request.id)
        end
      end

      -- Return to wait position after job
      parkAtWaitPosition()
    else
      -- No pending requests; check storage fill level and evacuate if needed
      local fill = getStationFill(tunnel, stationId)
      if fill then
        bus.state = "waiting (" .. fill.filled .. "/" .. fill.total .. " filled)"
        if fill.filled >= STORAGE_THRESHOLD_HIGH then
          bus.state = "evacuating"
          util.log(("hauler: storage %d/%d filled (>= %d), starting evacuation"):format(
            fill.filled, fill.total, STORAGE_THRESHOLD_HIGH))
          evacuateStorage(tunnel, stationId, turtleId, navInstance, surfaceY, 8)
        end
      else
        bus.state = "waiting"
      end
    end

    os.sleep(5)
  end
end

return M
