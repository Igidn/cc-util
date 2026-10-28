-- Deterministic 3D serpentine plan.
--
-- The base is the centre of a square sector. The first layer walks -Z to +Z,
-- the next layer walks back, and every layer drops LAYER_STEP at the end.
-- A leg is a straight run; the executor only needs (leg, offset) to resume.
local M = {}

local function addLine(legs, dir, length, layer, strip)
  if length > 0 then
    legs[#legs + 1] = {
      kind = "line",
      dir = dir,
      length = length,
      layer = layer,
      strip = strip,
    }
  end
end

function M.build(spec)
  local half = spec.maxRadius
  local staging = spec.staging or 1
  -- Lanes split the sector along X. Both miners share the same Z range, so
  -- each one gets its own X slice and they never mine the same blocks.
  local x0 = spec.sector and spec.sector.x0 or -half
  local x1 = spec.sector and spec.sector.x1 or half
  local z0 = spec.sector and spec.sector.z0 or (-half - staging)
  local z1 = spec.sector and spec.sector.z1 or (half - staging)
  local legs = {}

  -- The dock is one block south of the shaft top; step into the shaft first.
  addLine(legs, 0, staging, 0, 0)

  if spec.startY < 0 then
    legs[#legs + 1] = {
      kind = "down",
      dir = 0,
      length = -spec.startY,
      layer = 0,
      strip = 0,
    }
  end

  -- From the shaft centre to the west edge of the lane, then north to its
  -- first row.
  if x0 < 0 then
    addLine(legs, 3, -x0, 0, 0) -- west
  elseif x0 > 0 then
    addLine(legs, 1, x0, 0, 0) -- east
  end
  addLine(legs, 0, (-staging) - z0, 0, 0) -- north

  local width = x1 - x0
  local strips = math.floor((z1 - z0) / spec.spacing) + 1
  local y = spec.startY
  local layer = 0
  local zDir = 1
  local xDir = 1 -- east; flips every strip

  while y >= spec.endY do
    for strip = 0, strips - 1 do
      addLine(legs, xDir, width, layer, strip)
      xDir = (xDir == 1) and 3 or 1
      if strip < strips - 1 then
        addLine(legs, zDir == 1 and 2 or 0, spec.spacing, layer, strip)
      end
    end

    if y - spec.layerStep < spec.endY then break end
    legs[#legs + 1] = {
      kind = "down",
      dir = 0,
      length = spec.layerStep,
      layer = layer,
      strip = strips - 1,
    }
    y = y - spec.layerStep
    zDir = -zDir
    layer = layer + 1
  end

  return legs
end

function M.total(legs)
  local sum = 0
  for i = 1, #legs do sum = sum + legs[i].length end
  return sum
end

function M.blocksBefore(legs, legIndex)
  local sum = 0
  for i = 1, math.min(legIndex - 1, #legs) do sum = sum + legs[i].length end
  return sum
end

function M.progressPercent(legs, progress)
  local total = M.total(legs)
  if total == 0 then return 100 end
  local done = M.blocksBefore(legs, progress.leg) + math.max(0, progress.offset)
  return math.min(100, math.floor((done / total) * 1000 + 0.5) / 10)
end

function M.copyProgress(p)
  return {
    leg = p.leg or 1,
    offset = p.offset or 0,
    layer = p.layer or 0,
    strip = p.strip or 0,
  }
end

-- Advance past complete legs. Returns true when the whole plan is complete.
function M.normalize(legs, progress)
  while progress.leg <= #legs do
    local leg = legs[progress.leg]
    if progress.offset < leg.length then
      progress.layer = leg.layer
      progress.strip = leg.strip
      return false
    end
    progress.leg = progress.leg + 1
    progress.offset = 0
  end
  return true
end

function M.complete(legs, progress)
  return progress.leg > #legs
end

function M.validate(spec, hard)
  if type(spec) ~= "table" then return nil, "missing mission spec" end
  if spec.kind ~= "branchMine" then return nil, "unknown mission kind" end
  if type(spec.base) ~= "table" then return nil, "missing base pose" end
  if type(spec.startY) ~= "number" or type(spec.endY) ~= "number" then
    return nil, "missing Y range"
  end
  if spec.startY > 0 then return nil, "startY must be <= 0 (base is y=0)" end
  if spec.endY > spec.startY then return nil, "endY must be at or below startY" end
  if type(spec.maxRadius) ~= "number" or spec.maxRadius < 4 then
    return nil, "maxRadius too small"
  end
  if spec.maxRadius > (hard.maxRadius or 128) then
    return nil, "maxRadius exceeds local cap"
  end
  if type(spec.staging) ~= "number" or spec.staging < 0 or spec.staging > 4 then
    return nil, "staging must be 0..4"
  end
  if -spec.endY > (hard.maxDepth or 200) then
    return nil, "depth exceeds local cap"
  end
  if type(spec.layerStep) ~= "number" or spec.layerStep < 1 then
    return nil, "layerStep must be >= 1"
  end
  if type(spec.spacing) ~= "number" or spec.spacing < 2 then
    return nil, "spacing must be >= 2"
  end
  if type(spec.maxTripBlocks) ~= "number" or spec.maxTripBlocks < 1 then
    return nil, "maxTripBlocks must be >= 1"
  end
  if type(spec.maxVeinBlocks) ~= "number" or spec.maxVeinBlocks < 0 then
    return nil, "maxVeinBlocks must be >= 0"
  end
  if type(spec.reserve) ~= "number" or spec.reserve < 0 then
    return nil, "reserve must be >= 0"
  end
  return true
end

return M
