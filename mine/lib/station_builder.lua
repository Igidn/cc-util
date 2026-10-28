-- Station builder. Builds a mining station: surface chests, shaft to Y10,
-- 12x12 room at Y10 (two blocks tall so the player can walk inside),
-- 32 storage chests + 1 refueling chest. Then transitions to hauler.
-- Requires GPS; if unavailable, alerts the console and waits.
local util = require("lib.util")
local pose = require("lib.pose")
local nav = require("lib.nav")
local hal = require("lib.hal")
local gps = require("lib.gps")
local dock = require("lib.dock")
local shaft = require("lib.shaft")

local M = {}

-- Chest layout: relative positions in the 12x12 room at Y10.
-- Room spans x:0..11, z:0..11 with aisles at z=2,4,6,8,10 between rows.
-- Each chest has air neighbors on both sides (x spaced by 2) and front/back
-- (aisle rows), so every chest is accessible.
-- 32 storage chests + 1 refueling chest = 33 total.
local CHEST_LAYOUT = {
  -- Row z=1 (6 chests)
  {x = 0, z = 1, kind = "storage", label = "Storage 01"},
  {x = 2, z = 1, kind = "storage", label = "Storage 02"},
  {x = 4, z = 1, kind = "storage", label = "Storage 03"},
  {x = 6, z = 1, kind = "storage", label = "Storage 04"},
  {x = 8, z = 1, kind = "storage", label = "Storage 05"},
  {x = 10, z = 1, kind = "storage", label = "Storage 06"},
  -- Row z=3 (6 chests)
  {x = 0, z = 3, kind = "storage", label = "Storage 07"},
  {x = 2, z = 3, kind = "storage", label = "Storage 08"},
  {x = 4, z = 3, kind = "storage", label = "Storage 09"},
  {x = 6, z = 3, kind = "storage", label = "Storage 10"},
  {x = 8, z = 3, kind = "storage", label = "Storage 11"},
  {x = 10, z = 3, kind = "storage", label = "Storage 12"},
  -- Row z=5 (6 chests)
  {x = 0, z = 5, kind = "storage", label = "Storage 13"},
  {x = 2, z = 5, kind = "storage", label = "Storage 14"},
  {x = 4, z = 5, kind = "storage", label = "Storage 15"},
  {x = 6, z = 5, kind = "storage", label = "Storage 16"},
  {x = 8, z = 5, kind = "storage", label = "Storage 17"},
  {x = 10, z = 5, kind = "storage", label = "Storage 18"},
  -- Row z=7 (6 chests)
  {x = 0, z = 7, kind = "storage", label = "Storage 19"},
  {x = 2, z = 7, kind = "storage", label = "Storage 20"},
  {x = 4, z = 7, kind = "storage", label = "Storage 21"},
  {x = 6, z = 7, kind = "storage", label = "Storage 22"},
  {x = 8, z = 7, kind = "storage", label = "Storage 23"},
  {x = 10, z = 7, kind = "storage", label = "Storage 24"},
  -- Row z=9 (6 chests)
  {x = 0, z = 9, kind = "storage", label = "Storage 25"},
  {x = 2, z = 9, kind = "storage", label = "Storage 26"},
  {x = 4, z = 9, kind = "storage", label = "Storage 27"},
  {x = 6, z = 9, kind = "storage", label = "Storage 28"},
  {x = 8, z = 9, kind = "storage", label = "Storage 29"},
  {x = 10, z = 9, kind = "storage", label = "Storage 30"},
  -- Row z=11 (2 chests at the ends)
  {x = 0, z = 11, kind = "storage", label = "Storage 31"},
  {x = 10, z = 11, kind = "storage", label = "Storage 32"},
  -- Refueling chest in the center aisle area (near shaft bottom)
  {x = 6, z = 6, kind = "refuel", label = "Refuel"},
}

local CHEST_COUNT = #CHEST_LAYOUT
-- Target world Y coordinate for the mine room floor.
-- The station builder digs from surface down to this Y level.
local TARGET_Y = 10

----------------------------------------------------------------------
-- GPS
----------------------------------------------------------------------

local function syncGps()
  local initPose = { x = 0, y = 0, z = 0, f = 0 }
  local ok, err = gps.syncPose(initPose, hal, true)
  if ok then
    util.log("station_builder: GPS synced")
    return true
  end
  util.log("station_builder: GPS unavailable:", err or "unknown")
  return false
end

local function reportGpsAlert(tunnel, stationId, turtleId)
  local payload = textutils.serializeJSON({ turtleId = turtleId })
  local response, err = http.post(tunnel .. "/api/stations/" .. stationId .. "/gps-alert", payload, {
    ["Content-Type"] = "application/json",
  })
  if not response then
    util.log("station_builder: gps-alert request failed:", err or "no response")
  else
    response.close()
  end
end

----------------------------------------------------------------------
-- Surface chest verification
----------------------------------------------------------------------

local function inspectDir(dir)
  if dir == "front" then return hal.inspect() end
  if dir == "back" then
    local ok = hal.turnLeft(); hal.turnLeft()
    local data = hal.inspect()
    hal.turnRight(); hal.turnRight()
    return data
  end
  return nil
end

local function verifySurfaceChests()
  local front = hal.inspect()
  if front and front.name and front.name:find("chest") then
    util.log("station_builder: surface fuel chest verified (front)")
  else
    util.log("station_builder: WARNING: no fuel chest at front")
    return false
  end

  local back = inspectDir("back")
  if back and back.name and back.name:find("chest") then
    util.log("station_builder: surface depot chest verified (back)")
  else
    util.log("station_builder: WARNING: no depot chest at back")
    return false
  end
  return true
end

----------------------------------------------------------------------
-- Shaft digging (surface to Y10)
----------------------------------------------------------------------

-- Drop all non-chest items into the block in front of the turtle.
-- Used to clear debris (stone, dirt, etc.) while preserving chest items.
local function dropDebrisFront()
  local dropped = 0
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and not (item.name and item.name:find("chest")) then
      hal.select(slot)
      if hal.drop() then dropped = dropped + 1 end
    end
  end
  return dropped
end

-- Return to surface depot chest and drop all non-chest items there.
-- navInstance is the turtle's current nav; surfaceY is the surface level.
-- Saves and restores x,z,f position so the turtle can resume where it left off.
-- Returns true if debris was dropped successfully (or no disposal needed).
local function disposeDebris(navInstance, surfaceY)
  local usedSlots = hal.usedSlots()
  if usedSlots <= 12 then return true end -- no need yet

  util.log("station_builder: inventory full (%d slots), disposing debris to surface depot", usedSlots)

  -- Save current position
  local saveX, saveY, saveZ, saveF = navInstance.pose.x, navInstance.pose.y, navInstance.pose.z, navInstance.pose.f

  -- Ascend to surface
  local dy = surfaceY - saveY
  if dy > 0 then
    for _ = 1, dy do
      local ok, err = nav.up(navInstance, 1)
      if not ok then
        hal.digUp()
        ok = nav.up(navInstance, 1)
        if not ok then
          util.log("station_builder: cannot ascend to surface, aborting debris disposal")
          return false
        end
      end
    end
  end

  -- Face the depot chest (behind the turtle at surface spawn)
  nav.face(navInstance, 2) -- south

  -- Drop non-chest items into the depot chest in front
  local dropped = dropDebrisFront()
  util.log("station_builder: dropped", dropped, "debris stacks into depot chest")

  -- Return down to work level
  if dy > 0 then
    for _ = 1, dy do
      local ok, err = nav.down(navInstance, 1)
      if not ok then return false, "cannot descend" end
    end
  end

  -- Restore facing
  nav.face(navInstance, saveF)
  util.log("station_builder: debris disposal complete, back at Y%d", navInstance.pose.y)
  return true
end

local function digShaftToY10(navInstance, surfaceY, targetY)
  local currentY = navInstance.pose.y
  if currentY <= targetY then
    util.log(("station_builder: already at or below target Y%d"):format(targetY))
    return true
  end

  local depth = currentY - targetY
  util.log(("station_builder: digging shaft down %d blocks to Y%d"):format(depth, targetY))
  for i = 1, depth do
    -- Inspect down and dig if blocked (same as miner's moveDownOne)
    local data = hal.inspectDown()
    if data and not hal.passable(data) then
      local ok, err = hal.digDown()
      if not ok then
        util.log(("station_builder: shaft digDown failed at depth %d: %s"):format(i, err or "unknown"))
        return false
      end
    end
    local ok, err = nav.down(navInstance, 1)
    if not ok then
      util.log(("station_builder: shaft dig failed at depth %d: %s"):format(i, err or "unknown"))
      return false
    end
    -- Dispose debris every 10 blocks to prevent inventory fill
    if i % 10 == 0 then
      util.log(("station_builder: shaft progress Y%d"):format(navInstance.pose.y))
      local ok, err = disposeDebris(navInstance, surfaceY)
      if not ok then
        util.log("station_builder: debris disposal failed:", err or "unknown")
        return false
      end
    end
  end
  util.log(("station_builder: shaft complete at Y%d"):format(navInstance.pose.y))
  return true
end

----------------------------------------------------------------------
-- Room digging (12x12 at Y10, two blocks tall: Y10 floor + Y11 headroom)
----------------------------------------------------------------------

-- Dig a 12x12 room two blocks tall at current Y level.
-- Y level is the floor (stone stays). Y+1 is cleared to air for headroom.
-- Turtle starts at shaft bottom (center of room) at Y level.
local function digRoom12x12(navInstance, surfaceY)
  local roomY = navInstance.pose.y
  local headroomY = roomY + 1
  util.log(("station_builder: digging 12x12 room at Y%d (headroom Y%d)"):format(roomY, headroomY))

  local startX = navInstance.pose.x
  local startZ = navInstance.pose.z

  -- Clear headroom layer (Y+1): 12x12 air space for walking.
  -- Move up to headroom level first.
  local ok = nav.up(navInstance, 1)
  if not ok then
    util.log("station_builder: cannot move up to headroom level:", "blocked")
    -- Try digging up first
    hal.digUp()
    ok = nav.up(navInstance, 1)
    if not ok then return nil, "cannot reach headroom level" end
  end

  -- Clear 12 rows in Z direction, 12 blocks in X direction at headroom level.
  -- Serpentine pattern: even rows head east, odd rows head west, so the turtle
  -- stays inside the 12x12 bounds. (Always facing east marched diagonally out of
  -- the room and dug a line instead of a room: 12 blocks east, turn right/south,
  -- 1 block, turn left/east, 12 blocks east again.)
  local cleared = 0
  for row = 0, 11 do
    local eastRow = (row % 2 == 0)
    nav.face(navInstance, eastRow and 1 or 3) -- east on even rows, west on odd rows
    for col = 0, 11 do
      local x = startX + (eastRow and col or (11 - col))
      local data = hal.inspect()
      if data and not hal.passable(data) then
        hal.dig()
      end
      if col < 11 then
        nav.forward(navInstance, 1)
      end
      cleared = cleared + 1
      -- Dispose debris every 24 blocks (2 rows) to prevent inventory fill
      if cleared % 24 == 0 then
        local ok, err = disposeDebris(navInstance, surfaceY)
        if not ok then
          util.log("station_builder: debris disposal failed:", err or "unknown")
          return false
        end
      end
    end
    if row < 11 then
      -- Step south to the next row; dig the block ahead in case it is stone
      nav.face(navInstance, 2) -- south
      local data = hal.inspect()
      if data and not hal.passable(data) then
        hal.dig()
      end
      nav.forward(navInstance, 1)
    end
  end

  util.log("station_builder: headroom cleared,", cleared, "blocks checked")

  -- Return to the shaft bottom (start position) at headroom level so roomOrigin
  -- lines up with the chest layout origin. Do not move down to the floor: the
  -- stone floor stays solid so chests rest on it.
  local dx = startX - navInstance.pose.x
  local dz = startZ - navInstance.pose.z
  if dx > 0 then nav.face(navInstance, 1) elseif dx < 0 then nav.face(navInstance, 3) end
  if dx ~= 0 then
    local ok, err = nav.forward(navInstance, math.abs(dx))
    if not ok then return nil, "return to shaft start (x) blocked: " .. tostring(err) end
  end
  if dz > 0 then nav.face(navInstance, 2) elseif dz < 0 then nav.face(navInstance, 0) end
  if dz ~= 0 then
    local ok, err = nav.forward(navInstance, math.abs(dz))
    if not ok then return nil, "return to shaft start (z) blocked: " .. tostring(err) end
  end

  util.log("station_builder: room floor at Y%d ready", roomY)
  return true
end

----------------------------------------------------------------------
-- Chest placement
----------------------------------------------------------------------

-- Count how many chest items are in inventory.
local function countChestsInInventory()
  local count = 0
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and item.name and item.name:find("chest") then
      count = count + (item.count or 1)
    end
  end
  return count
end

-- Select a slot containing a chest and place it down.
-- Turtle must be at Y+1 relative to where the chest goes (places at Y).
local function placeChestDown()
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and item.name and item.name:find("chest") then
      hal.select(slot)
      local ok, err = hal.placeDown()
      if ok then
        return true
      end
      util.log("station_builder: placeDown failed:", err or "unknown")
      return false
    end
  end
  return false, "no chest in inventory"
end

-- Navigate to a specific (x, z) position at headroom level (Y+1),
-- then place a chest down at floor level (Y).
local function placeChestAt(navInstance, targetX, targetZ, floorY)
  -- Move to headroom level (floorY + 1)
  local headroomY = floorY + 1
  local dy = headroomY - navInstance.pose.y
  if dy > 0 then
    for _ = 1, dy do
      local ok, err = nav.up(navInstance, 1)
      if not ok then
        hal.digUp()
        ok = nav.up(navInstance, 1)
        if not ok then return nil, "cannot move up" end
      end
    end
  elseif dy < 0 then
    for _ = 1, -dy do
      local ok, err = nav.down(navInstance, 1)
      if not ok then return nil, "cannot move down" end
    end
  end

  -- Move in X
  local dx = targetX - navInstance.pose.x
  if dx > 0 then
    nav.face(navInstance, 1)
    for _ = 1, dx do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "east blocked at x=" .. targetX end
    end
  elseif dx < 0 then
    nav.face(navInstance, 3)
    for _ = 1, -dx do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "west blocked at x=" .. targetX end
    end
  end

  -- Move in Z
  local dz = targetZ - navInstance.pose.z
  if dz > 0 then
    nav.face(navInstance, 2)
    for _ = 1, dz do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "south blocked at z=" .. targetZ end
    end
  elseif dz < 0 then
    nav.face(navInstance, 0)
    for _ = 1, -dz do
      local ok, err = nav.step(navInstance, "forward")
      if not ok then return nil, "north blocked at z=" .. targetZ end
    end
  end

  -- Make sure the floor block below is air so the chest can be placed at
  -- floor level (it will rest on the solid stone beneath the floor).
  local below = hal.inspectDown()
  if below and not hal.passable(below) then
    local ok, err = hal.digDown()
    if not ok then
      return nil, ("floor dig failed at %d,%d: %s"):format(targetX, targetZ, tostring(err))
    end
  end

  -- Place chest down at floor level
  local ok, err = placeChestDown()
  if not ok then
    return nil, err or "placeDown failed"
  end
  return true
end

-- Place all chests from CHEST_LAYOUT. Handles inventory restocking.
local function placeAllChests(navInstance, tunnel, stationId, turtleId, roomOrigin, floorY)
  local placed = 0
  local chestIdNum = 1

  for _, entry in ipairs(CHEST_LAYOUT) do
    local targetX = roomOrigin.x + entry.x
    local targetZ = roomOrigin.z + entry.z

    -- Check if we have a chest in inventory
    local chestCount = countChestsInInventory()
    if chestCount == 0 then
      util.log("station_builder: out of chests, need restock")
      return false, "out of chests"
    end

    -- Navigate to chest position and place down
    local ok, err = placeChestAt(navInstance, targetX, targetZ, floorY)
    if not ok then
      util.log("station_builder: failed to place chest at", entry.label or "?", err or "unknown")
    else
      placed = placed + 1
      local chestId
      if entry.kind == "refuel" then
        chestId = string.format("s%s-c-refuel", stationId:sub(2))
      else
        chestId = string.format("s%s-c%03d", stationId:sub(2), chestIdNum)
        chestIdNum = chestIdNum + 1
      end

      -- Register chest with console
      local chestPose = { x = targetX, y = floorY, z = targetZ, f = navInstance.pose.f }
      local payload = textutils.serializeJSON({
        id = chestId,
        stationId = stationId,
        kind = entry.kind,
        pose = chestPose,
        label = entry.label,
      })
      local resp, rerr = http.post(tunnel .. "/api/chests", payload, {
        ["Content-Type"] = "application/json",
      })
      if resp then
        resp.close()
        util.log("station_builder: registered", chestId, entry.kind, "at", targetX, floorY, targetZ)
      else
        util.log("station_builder: failed to register", chestId, ":", rerr or "unknown")
      end
    end
  end

  util.log("station_builder: placed", placed, "of", CHEST_COUNT, "chests")
  return placed == CHEST_COUNT
end

----------------------------------------------------------------------
-- Transition to hauler
----------------------------------------------------------------------

local function reportGeometry(tunnel, stationId, turtleId, shaftX, shaftZ, surfaceY, floorY)
  local payload = textutils.serializeJSON({
    turtleId = turtleId,
    shaftPose = { x = shaftX, y = surfaceY, z = shaftZ, f = 0 },
    roomPose = { x = shaftX, y = floorY + 1, z = shaftZ, f = 0 },
    dockPose = { x = shaftX, y = floorY + 1, z = shaftZ + 1, f = 0 },
  })
  local response, err = http.post(tunnel .. "/api/stations/" .. stationId .. "/geometry", payload, {
    ["Content-Type"] = "application/json",
  })
  if not response then
    util.log("station_builder: geometry report failed:", err or "no response")
    return false
  end
  local code = response.getResponseCode()
  local body = response.readAll()
  response.close()
  if code ~= 200 then
    util.log("station_builder: geometry rejected:", code, body)
    return false
  end
  util.log("station_builder: reported geometry for", stationId)
  return true
end

-- Register the two surface chests the station layout expects: fuel in front of
-- the builder's start pose and the depot behind it. Future haulers use these
-- positions to fetch lava and to drop off ores.
local function registerSurfaceChests(tunnel, stationId, base)
  local dx, dz = pose.vec(base.f)
  local function register(id, kind, x, y, z, label)
    local payload = textutils.serializeJSON({
      id = id,
      stationId = stationId,
      kind = kind,
      pose = { x = x, y = y, z = z, f = base.f },
      label = label,
    })
    local response, err = http.post(tunnel .. "/api/chests", payload, {
      ["Content-Type"] = "application/json",
    })
    if not response then
      util.log("station_builder: failed to register", kind, "chest:", err or "no response")
      return false
    end
    response.close()
    util.log("station_builder: registered", kind, "chest at", x, y, z)
    return true
  end

  local front = hal.inspect()
  if front and front.name and front.name:find("chest") then
    register(string.format("s%s-c-fuel", stationId:sub(2)), "fuel",
      base.x + dx, base.y, base.z + dz, "Fuel")
  end
  local back = inspectDir("back")
  if back and back.name and back.name:find("chest") then
    register(string.format("s%s-c-depot", stationId:sub(2)), "depot",
      base.x - dx, base.y, base.z - dz, "Depot")
  end
end

local function transitionToHauler(tunnel, turtleId)
  local payload = textutils.serializeJSON({ role = "hauler" })
  local response, err = http.post(tunnel .. "/api/turtles/" .. turtleId .. "/assign-role", payload, {
    ["Content-Type"] = "application/json",
  })
  if not response then
    util.log("station_builder: transition to hauler failed:", err or "no response")
    return false
  end
  response.close()
  util.log("station_builder: transitioned to hauler")
  return true
end

----------------------------------------------------------------------
-- Main run
----------------------------------------------------------------------

function M.run(id, bus)
  local tunnel = bus.serverUrl
  if not tunnel then
    util.log("station_builder: no server URL, cannot operate")
    return nil, "no server URL"
  end

  local stationId = bus.station and bus.station.id or "s0"
  local turtleId = id

  -- A builder is a one-shot role. If this station is already built, do not
  -- rebuild on top of it (a reboot used to re-run the builder and overwrite the
  -- reported geometry and chest coordinates with a shifted copy). Finish the
  -- builder's normal life cycle by handing the turtle to the hauler instead.
  if bus.station and bus.station.built and bus.station.shaftPose then
    util.log("station_builder: station already built; not rebuilding")
    transitionToHauler(tunnel, turtleId)
    return "transition_to_hauler"
  end

  -- 1. GPS sync
  local gpsOk = syncGps()
  if not gpsOk then
    util.log("station_builder: GPS unavailable, alerting console and waiting")
    reportGpsAlert(tunnel, stationId, turtleId)
    while true do
      os.sleep(10)
      if syncGps() then
        util.log("station_builder: GPS restored, resuming")
        break
      end
    end
  end

  -- 2. Verify surface chests
  if not verifySurfaceChests() then
    util.log("station_builder: surface chests not verified, continuing anyway")
  end

  -- 3. Dock zero for position reference
  local base, derr = dock.zero(hal, bus.pose or { x = 0, y = 0, z = 0, f = 0 })
  if not base then
    util.log("station_builder: dock zero failed:", derr or "unknown")
  end

  local surfaceY = (base and base.y) or (bus.pose and bus.pose.y) or 0
  -- A builder started inside an existing room reports the room itself as the
  -- surface and digs a one-block shaft that miners cannot use. Refuse instead.
  if surfaceY <= TARGET_Y + 1 then
    util.log(("station_builder: started at Y%d, not at the surface; move it up and assign the role again"):format(surfaceY))
    return nil, ("station builder must start above Y%d"):format(TARGET_Y + 1)
  end

  -- Remember the surface fuel/depot chests for the hauler before digging.
  if base then registerSurfaceChests(tunnel, stationId, base) end

  util.log(("station_builder: surface at Y%d, digging shaft down to Y%d"):format(surfaceY, TARGET_Y))

  -- 4. Create nav instance from dock-zeroed base pose (real world coordinates)
  local navInstance = nav.new(hal, nil, 0, base or { x = 0, y = surfaceY, z = 0, f = 0 }, true)

  -- 5. Dig shaft down to TARGET_Y
  if not digShaftToY10(navInstance, surfaceY, TARGET_Y) then
    return nil, "shaft dig failed"
  end

  local floorY = navInstance.pose.y
  util.log(("station_builder: shaft bottom at Y%d (floor level)"):format(floorY))

  -- Acquire shaft lock for the room work (non-critical for single turtle).
  -- If the HTTP request fails, proceed without the lock.
  local acquired = shaft.acquire(tunnel, stationId, turtleId, "station_build")
  if not acquired then
    util.log("station_builder: could not acquire shaft lock, proceeding without lock")
  end

  -- 6. Dig 12x12 room at floorY (two blocks tall: floor + headroom)
  if not digRoom12x12(navInstance, surfaceY) then
    shaft.release(tunnel, stationId, turtleId)
    return nil, "room dig failed"
  end

  -- Dispose any remaining debris before chest placement
  local ok, err = disposeDebris(navInstance, surfaceY)
  if not ok then
    util.log("station_builder: final debris disposal failed:", err or "unknown")
  end

  -- 7. Place all chests
  local roomOrigin = { x = navInstance.pose.x, z = navInstance.pose.z }
  local ok, err = placeAllChests(navInstance, tunnel, stationId, turtleId, roomOrigin, floorY)
  if not ok then
    util.log("station_builder: chest placement incomplete:", err or "unknown")
  end

  -- Return to shaft bottom (center of room) at floor level
  local shaftX = roomOrigin.x
  local shaftZ = roomOrigin.z
  local dx = shaftX - navInstance.pose.x
  local dz = shaftZ - navInstance.pose.z
  if dx > 0 then nav.face(navInstance, 1) elseif dx < 0 then nav.face(navInstance, 3) end
  for _ = 1, math.abs(dx) do nav.step(navInstance, "forward") end
  if dz > 0 then nav.face(navInstance, 2) elseif dz < 0 then nav.face(navInstance, 0) end
  for _ = 1, math.abs(dz) do nav.step(navInstance, "forward") end

  -- 8. Report the real world geometry so missions can base themselves on the
  -- room instead of the synthetic station anchor. A rejected report means the
  -- station would be unusable, so stay a builder and surface the error.
  local reported = reportGeometry(tunnel, stationId, turtleId, shaftX, shaftZ, surfaceY, floorY)

  -- 9. Release shaft lock
  shaft.release(tunnel, stationId, turtleId)

  if not reported then
    return nil, "station geometry was rejected; check that the builder started on the surface"
  end

  -- 10. Transition to hauler
  transitionToHauler(tunnel, turtleId)

  return "transition_to_hauler"
end

M.CHEST_LAYOUT = CHEST_LAYOUT
M.CHEST_COUNT = CHEST_COUNT
-- Exported for tests/simulator
M.digRoom12x12 = digRoom12x12
M.placeChestAt = placeChestAt

return M