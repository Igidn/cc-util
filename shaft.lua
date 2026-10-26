-- shaft.lua - Simple vertical shaft miner for CC:Tweaked
-- Usage: wget https://raw.githubusercontent.com/Igidn/cc-util/main/shaft.lua shaft.lua
--        shaft <depth>    (default 778)
-- Mines straight down to depth, then returns to surface.

local DEPTH = tonumber(arg[1]) or 778
local FUEL_RESERVE = 50  -- keep this much fuel for emergencies

local function log(msg)
  print(("[@%d] %s"):format(os.clock(), msg))
end

local function refuel()
  for i = 1, 16 do
    turtle.select(i)
    if turtle.refuel(0) then
      turtle.refuel()
    end
  end
  turtle.select(1)
end

local function ensureFuel(needed)
  refuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel >= needed + FUEL_RESERVE then return true end
  log(("Low fuel: %d, need %d. Waiting for fuel..."):format(fuel, needed))
  while true do
    refuel()
    fuel = turtle.getFuelLevel()
    if fuel == "unlimited" or fuel >= needed + FUEL_RESERVE then
      log("Fuel OK: " .. tostring(fuel))
      return true
    end
    sleep(5)
  end
end

local function digDown()
  while turtle.detectDown() do
    if not turtle.digDown() then
      local ok, data = turtle.inspectDown()
      if ok and data.name:find("lava") then
        log("Lava below, placing block...")
        turtle.select(1)
        turtle.placeDown()
      else
        return false, "cannot dig down"
      end
    end
  end
  return true
end

local function digForward()
  while turtle.detect() do
    if not turtle.dig() then
      local ok, data = turtle.inspect()
      if ok and data.name:find("lava") then
        log("Lava ahead, placing block...")
        turtle.select(1)
        turtle.place()
      else
        return false, "cannot dig forward"
      end
    end
  end
  return true
end

local function moveDown()
  ensureFuel(1)
  digDown()
  local ok, err = turtle.down()
  if not ok then return false, err end
  return true
end

local function moveUp()
  ensureFuel(1)
  local ok, err = turtle.up()
  if not ok then return false, err end
  return true
end

-- Main shaft mining
log(("Starting shaft to depth %d"):format(DEPTH))

-- Check initial fuel
local fuel = turtle.getFuelLevel()
if fuel ~= "unlimited" then
  local needed = DEPTH * 2 + FUEL_RESERVE
  log(("Fuel check: have %d, need ~%d"):format(fuel, needed))
  ensureFuel(needed)
end

local depth = 0
local maxDepth = DEPTH

-- Mine down
while depth < maxDepth do
  local ok, err = moveDown()
  if not ok then
    log("Failed to move down: " .. tostring(err))
    break
  end
  depth = depth + 1
  if depth % 50 == 0 then
    log(("Depth: %d/%d"):format(depth, maxDepth))
  end
end

log(("Reached depth %d, returning to surface..."):format(depth))

-- Return up
while depth > 0 do
  local ok, err = moveUp()
  if not ok then
    log("Failed to move up: " .. tostring(err))
    break
  end
  depth = depth - 1
  if depth % 50 == 0 then
    log(("Ascending: %d blocks remaining"):format(depth))
  end
end

log("Back at surface. Shaft complete!")