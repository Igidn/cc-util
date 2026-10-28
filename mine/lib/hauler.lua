-- Hauler. Three jobs:
--  (A) Carry lava from the surface fuel chest down to the station refuel chest.
--  (B) Move items up to the surface depot chest when storage fills up.
--  (C) Deliver player-requested items from underground storage to the depot.
-- Every shaft traversal goes through the console's shaft queue.
--
-- Surface layout the builder sets up (and registers as chests):
--   fuel chest  - in front of the builder's start pose, north
--   depot chest - behind it, south
-- The room layout: refuel chest on the floor, one block below the walk level.
local util = require("lib.util")
local pose = require("lib.pose")
local nav = require("lib.nav")
local hal = require("lib.hal")
local gps = require("lib.gps")
local shaft = require("lib.shaft")

local M = {}

local STORAGE_THRESHOLD_HIGH = 28 -- 3.5/4 of 32 -> start moving items up
local EVACUATE_TARGET_FILL = 12   -- stop evacuating at ~3/8 full
local ASCENT_MARGIN = 64          -- extra fuel kept for the walk back to the shaft
local MAX_WAIT = 120              -- seconds to wait for station geometry

local function log(...)
  util.log("hauler:", ...)
end

local function send(bus, msg)
  if bus and bus.send then bus.send(msg) end
end

-- Keep the console's copy of our pose in sync while we move.
local function publish(bus, trip, stateName)
  if bus and trip then
    bus.pose = pose.copy(trip.pose)
    bus.state = stateName or bus.state
  end
end

----------------------------------------------------------------------
-- Station geometry and chests
----------------------------------------------------------------------

-- The welcome (or the assignRole that switched us to hauler) carries the
-- station with its reported geometry. Wait briefly in case it lands late.
local function stationGeometry(bus)
  for _ = 1, MAX_WAIT do
    local station = bus.station
    if station and station.shaftPose and station.roomPose then return station end
    os.sleep(1)
  end
  return nil
end

local function fetchChests(tunnel, stationId)
  local response, err = http.get(tunnel .. "/api/chests?stationId=" .. stationId, {
    ["User-Agent"] = "cc-util/0.1.0",
  })
  if not response then
    log("chest fetch failed:", err or "no response")
    return {}
  end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then
    log("chest fetch returned", code)
    return {}
  end
  local data = util.jsonDecode(text)
  if not data or type(data.chests) ~= "table" then return {} end
  return data.chests
end

local function findChest(chests, kind, nearX, nearZ)
  local best, bestDist = nil, math.huge
  for _, chest in ipairs(chests) do
    if chest.kind == kind and chest.pose then
      local dx = chest.pose.x - (nearX or chest.pose.x)
      local dz = chest.pose.z - (nearZ or chest.pose.z)
      local dist = dx * dx + dz * dz
      if dist < bestDist then
        best, bestDist = chest, dist
      end
    end
  end
  return best
end

----------------------------------------------------------------------
-- Movement
----------------------------------------------------------------------

local function faceCell(trip, x, z)
  local dx, dz = x - trip.pose.x, z - trip.pose.z
  if dx == 0 and dz == 0 then return true end
  if math.abs(dx) > math.abs(dz) then
    return nav.face(trip, dx > 0 and 1 or 3)
  end
  return nav.face(trip, dz > 0 and 2 or 0)
end

-- Walk on one level. Never digs: the room and surface are supposed to be open.
local function moveHoriz(trip, x, z, bus)
  local dx = x - trip.pose.x
  if dx > 0 then
    if not nav.face(trip, 1) then return nil, "face east failed" end
  elseif dx < 0 then
    if not nav.face(trip, 3) then return nil, "face west failed" end
  end
  for _ = 1, math.abs(dx) do
    local ok, err = nav.step(trip, "forward")
    if not ok then return nil, "east/west blocked: " .. tostring(err) end
    publish(bus, trip)
  end
  local dz = z - trip.pose.z
  if dz > 0 then
    if not nav.face(trip, 2) then return nil, "face south failed" end
  elseif dz < 0 then
    if not nav.face(trip, 0) then return nil, "face north failed" end
  end
  for _ = 1, math.abs(dz) do
    local ok, err = nav.step(trip, "forward")
    if not ok then return nil, "north/south blocked: " .. tostring(err) end
    publish(bus, trip)
  end
  return true
end

-- Move vertically inside the shaft. Refuses hazards and refuses to dig, so a
-- blocked shaft stops the hauler instead of carving through the room.
local function moveVertical(trip, targetY, dir, bus)
  local dy = targetY - trip.pose.y
  if dy == 0 then return true end
  local steps = math.abs(dy)
  for _ = 1, steps do
    local data = dir == "down" and hal.inspectDown() or hal.inspectUp()
    if data and hal.hazard(data) then
      return nil, "hazard in the shaft at Y" .. (trip.pose.y + (dir == "down" and -1 or 1))
    end
    if data and not hal.passable(data) then
      return nil, ("shaft blocked at Y%d by %s"):format(
        trip.pose.y + (dir == "down" and -1 or 1), data.name or "?")
    end
    local ok, err
    if dir == "down" then ok, err = nav.down(trip, 1) else ok, err = nav.up(trip, 1) end
    if not ok then return nil, (dir .. " failed: " .. tostring(err)) end
    publish(bus, trip)
  end
  return true
end

----------------------------------------------------------------------
-- Chest interaction
----------------------------------------------------------------------

local function countFuel()
  local count, slots = 0, {}
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and hal.isFuel(item.name) then
      count = count + (item.count or 0)
      slots[#slots + 1] = slot
    end
  end
  return count, slots
end

-- Pull from the chest in front of the turtle until it stops giving.
local function suckFront(limit)
  local got = 0
  for _ = 1, limit do
    if not hal.suck() then break end
    got = got + 1
  end
  return got
end

-- Pull from the chest below the turtle (used when standing on top).
local function suckBelow(limit)
  local got = 0
  for _ = 1, limit do
    if not hal.suckDown() then break end
    got = got + 1
  end
  return got
end

-- Stand next to a chest at the given level, face it, and pull items.
-- Tries all four sides, then the cell above the chest.
local function suckFromChest(trip, chest, bus)
  local cx, cy, cz = chest.pose.x, chest.pose.y, chest.pose.z
  local sides = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for _, off in ipairs(sides) do
    local sx, sz = cx + off[1], cz + off[2]
    if moveHoriz(trip, sx, sz, bus) then
      faceCell(trip, cx, cz)
      local seen = hal.inspect()
      if seen and seen.name and seen.name:find("chest") then
        local got = suckFront(64)
        if got > 0 then
          log("collected", got, "items from", chest.kind, "chest")
          return got
        end
      end
    end
  end
  -- Fall back to standing on top of the chest.
  if moveHoriz(trip, cx, cz, bus) then
    local ok = moveVertical(trip, cy + 1, "up", bus)
    if ok then
      local got = suckBelow(64)
      if got > 0 then
        log("collected", got, "items from", chest.kind, "chest (above)")
        return got
      end
    end
  end
  return 0
end

-- Drop fuel items into the chest directly below the turtle.
local function dropFuelDown()
  local dropped = 0
  for slot = 1, 16 do
    local item = hal.itemDetail(slot)
    if item and hal.isFuel(item.name) then
      hal.select(slot)
      if hal.dropDown() then dropped = dropped + 1 end
    end
  end
  return dropped
end

-- Drop everything except chests into the chest the turtle faces.
local function dropFront()
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

-- Stand next to the depot chest and drop inventory into it.
local function dropIntoDepot(trip, depot, bus)
  local cx, cy, cz = depot.pose.x, depot.pose.y, depot.pose.z
  local sides = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for _, off in ipairs(sides) do
    local sx, sz = cx + off[1], cz + off[2]
    if moveHoriz(trip, sx, sz, bus) then
      faceCell(trip, cx, cz)
      local seen = hal.inspect()
      if seen and seen.name and seen.name:find("chest") then
        return dropFront()
      end
    end
  end
  return 0
end

----------------------------------------------------------------------
-- Shaft traversal
----------------------------------------------------------------------

local function goToShaftTop(trip, geometry, bus)
  return moveHoriz(trip, geometry.shaftPose.x, geometry.shaftPose.z, bus)
end

local function descendToRoom(trip, geometry, bus)
  local shaftPose, roomPose = geometry.shaftPose, geometry.roomPose
  local ok, err = moveHoriz(trip, shaftPose.x, shaftPose.z, bus)
  if not ok then return nil, err end
  if trip.pose.y < shaftPose.y then
    ok, err = moveVertical(trip, shaftPose.y, "up", bus)
    if not ok then return nil, err end
  end
  return moveVertical(trip, roomPose.y, "down", bus)
end

local function ascendToSurface(trip, geometry, bus)
  local shaftPose, roomPose = geometry.shaftPose, geometry.roomPose
  if trip.pose.y ~= roomPose.y then
    local ok, err = moveVertical(trip, roomPose.y, trip.pose.y > roomPose.y and "down" or "up", bus)
    if not ok then return nil, err end
  end
  local ok, err = moveHoriz(trip, shaftPose.x, shaftPose.z, bus)
  if not ok then return nil, err end
  return moveVertical(trip, shaftPose.y, "up", bus)
end

----------------------------------------------------------------------
-- Fuel delivery (down)
----------------------------------------------------------------------

local function deliverFuel(tunnel, stationId, turtleId, trip, geometry, chests, bus)
  local fuelChest = findChest(chests, "fuel", trip.pose.x, trip.pose.z)
  local refuelChest = findChest(chests, "refuel", geometry.roomPose.x, geometry.roomPose.z)
  if not refuelChest then
    log("no refuel chest registered; cannot deliver fuel")
    return false
  end

  -- Top up from the surface chest when there is one, otherwise use whatever
  -- lava the operator loaded into the hauler.
  if fuelChest and trip.pose.y >= geometry.shaftPose.y then
    local got = suckFromChest(trip, fuelChest, bus)
    if got == 0 then log("surface fuel chest is empty or unreachable") end
  end

  local carried = countFuel()
  if carried == 0 then
    log("no fuel in inventory; nothing to deliver")
    return false
  end

  -- Keep enough fuel to come back up. Take it one item at a time so the rest
  -- of the load is still delivered to the refuel chest.
  local depth = geometry.shaftPose.y - geometry.roomPose.y
  local needed = depth * 2 + ASCENT_MARGIN
  local fuel = hal.fuel()
  local refuels = 0
  while type(fuel) == "number" and fuel < needed and refuels < 64 do
    if countFuel() == 0 then break end
    local ok = hal.refuelFromInventory(1)
    if not ok then break end
    local nextFuel = hal.fuel()
    if type(nextFuel) ~= "number" or nextFuel <= fuel then break end
    fuel = nextFuel
    refuels = refuels + 1
  end
  if type(fuel) == "number" and fuel < needed then
    log(("not enough fuel for the round trip (have %d, need %d)"):format(fuel, needed))
    return false
  end

  if not shaft.acquire(tunnel, stationId, turtleId, "fuel_delivery") then
    log("could not acquire shaft for fuel delivery")
    return false
  end

  bus.state = "descending with fuel"
  local ok, err = descendToRoom(trip, geometry, bus)
  if not ok then
    shaft.release(tunnel, stationId, turtleId)
    log("fuel descent failed:", err)
    return false
  end

  ok, err = moveHoriz(trip, refuelChest.pose.x, refuelChest.pose.z, bus)
  if ok and trip.pose.y ~= refuelChest.pose.y + 1 then
    -- The room walk level should be directly above the chest.
    if trip.pose.y > refuelChest.pose.y + 1 then
      ok, err = moveVertical(trip, refuelChest.pose.y + 1, "down", bus)
    else
      ok, err = moveVertical(trip, refuelChest.pose.y + 1, "up", bus)
    end
  end
  if not ok then
    shaft.release(tunnel, stationId, turtleId)
    log("could not reach the refuel chest:", err)
    return false
  end

  faceCell(trip, refuelChest.pose.x, refuelChest.pose.z)
  local dropped = dropFuelDown()
  log("dropped", dropped, "fuel stacks into the refuel chest")

  bus.state = "ascending"
  ok, err = ascendToSurface(trip, geometry, bus)
  shaft.release(tunnel, stationId, turtleId)
  if not ok then
    log("fuel ascent failed:", err)
    return false
  end

  -- Park clear of the shaft and the fuel chest.
  local parkX = geometry.shaftPose.x + 1
  moveHoriz(trip, parkX, geometry.shaftPose.z, bus)
  bus.state = "waiting"
  return dropped > 0
end

----------------------------------------------------------------------
-- Items up (evacuation and player requests)
----------------------------------------------------------------------

local function getStationFill(tunnel, stationId)
  local chests = fetchChests(tunnel, stationId)
  local filled, total = 0, 0
  for _, chest in ipairs(chests) do
    if chest.kind == "storage" then
      total = total + 1
      if chest.fillPercent and chest.fillPercent > 0 then filled = filled + 1 end
    end
  end
  return { filled = filled, total = total, chests = chests }
end

-- Collect from storage chests and drop everything at the surface depot.
local function moveItemsUp(tunnel, stationId, turtleId, trip, geometry, chests, bus)
  local depot = findChest(chests, "depot", geometry.shaftPose.x, geometry.shaftPose.z)
  if not depot then
    log("no depot chest registered; cannot move items up")
    return false
  end
  local storage = findChest(chests, "storage", geometry.roomPose.x, geometry.roomPose.z)
  if not storage then
    log("no storage chest registered")
    return false
  end

  if not shaft.acquire(tunnel, stationId, turtleId, "item_delivery") then
    log("could not acquire shaft for item delivery")
    return false
  end

  bus.state = "collecting items"
  local ok, err = descendToRoom(trip, geometry, bus)
  if ok then
    ok, err = moveHoriz(trip, storage.pose.x, storage.pose.z, bus)
    if ok and trip.pose.y > storage.pose.y + 1 then
      ok, err = moveVertical(trip, storage.pose.y + 1, "down", bus)
    end
  end
  if not ok then
    shaft.release(tunnel, stationId, turtleId)
    log("could not reach storage:", err)
    return false
  end

  local collected = suckBelow(64)
  log("collected", collected, "items from storage")
  if collected == 0 then
    shaft.release(tunnel, stationId, turtleId)
    return false
  end

  bus.state = "hauling items up"
  ok, err = ascendToSurface(trip, geometry, bus)
  if not ok then
    shaft.release(tunnel, stationId, turtleId)
    log("item ascent failed:", err)
    return false
  end

  local dropped = dropIntoDepot(trip, depot, bus)
  shaft.release(tunnel, stationId, turtleId)
  log("dropped", dropped, "items into the depot chest")
  bus.state = "waiting"
  return dropped > 0
end

----------------------------------------------------------------------
-- Player requests (polled; delivered as a normal haul up)
----------------------------------------------------------------------

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

local function assignRequest(tunnel, requestId, turtleId)
  local payload = textutils.serializeJSON({ haulerId = turtleId })
  local response = http.post(tunnel .. "/api/requests/" .. requestId .. "/assign", payload, {
    ["Content-Type"] = "application/json",
  })
  if not response then return false end
  response.close()
  return true
end

local function deliverRequest(tunnel, requestId)
  local response = http.post(tunnel .. "/api/requests/" .. requestId .. "/deliver", "", {
    ["Content-Type"] = "application/json",
  })
  if not response then return false end
  response.close()
  return true
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

function M.run(id, bus)
  local tunnel = bus.serverUrl
  if not tunnel then
    log("no server URL, cannot operate")
    return nil, "no server URL"
  end

  local stationId = bus.station and bus.station.id or "s0"
  local turtleId = id

  -- GPS is available at the surface, which is where the hauler starts.
  local startPose = pose.copy(bus.pose or { x = 0, y = 0, z = 0, f = 0 })
  local gok = gps.syncPose(startPose, hal, true)
  if gok then
    log("GPS synced at", startPose.x, startPose.y, startPose.z)
  else
    log("GPS unavailable; working from the last known pose")
  end

  local geometry = stationGeometry(bus)
  if not geometry then
    log("station geometry never arrived; is the station built?")
    return nil, "station geometry missing"
  end
  log("station", stationId, "shaft top", geometry.shaftPose.y)

  local trip = nav.new(hal, nil, 0, startPose, true)
  publish(bus, trip, "waiting")

  -- Park beside the shaft so we do not block a miner's transit.
  moveHoriz(trip, geometry.shaftPose.x + 1, geometry.shaftPose.z, bus)

  local fuelRetryAt = 0

  while true do
    bus.state = "waiting"
    local chests = fetchChests(tunnel, stationId)

    -- Fuel first: the miners need it to get back out. Retry slowly when a
    -- delivery fails (for example when the refuel chest is full).
    local carried = countFuel()
    local fuelChest = findChest(chests, "fuel", trip.pose.x, trip.pose.z)
    if carried > 0 or fuelChest then
      if os.time() >= fuelRetryAt then
        local ok = deliverFuel(tunnel, stationId, turtleId, trip, geometry, chests, bus)
        if not ok then fuelRetryAt = os.time() + 60 end
      end
    end

    if bus.role ~= "hauler" then
      log("role changed to", tostring(bus.role), "; stopping")
      return nil, "role changed"
    end

    local request = pollRequest(tunnel, stationId)
    if request then
      bus.state = "delivering request"
      if assignRequest(tunnel, request.id, turtleId) then
        if moveItemsUp(tunnel, stationId, turtleId, trip, geometry, chests, bus) then
          deliverRequest(tunnel, request.id)
          log("request delivered", request.id)
        else
          log("request delivery failed", request.id)
        end
      end
    else
      local fill = getStationFill(tunnel, stationId)
      if fill and fill.filled >= STORAGE_THRESHOLD_HIGH then
        bus.state = "evacuating"
        log(("storage %d/%d filled, evacuating"):format(fill.filled, fill.total))
        local trips = 0
        while trips < 8 do
          local before = getStationFill(tunnel, stationId)
          if not before or before.filled <= EVACUATE_TARGET_FILL then break end
          if not moveItemsUp(tunnel, stationId, turtleId, trip, geometry, before.chests, bus) then break end
          trips = trips + 1
        end
      end
    end

    os.sleep(5)
  end
end

return M
