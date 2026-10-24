local M = {}

local VERSION = "0.1.0"
M.VERSION = VERSION

local seeded = false
local function seed()
  if seeded then return end
  seeded = true
  local ok = pcall(function()
    math.randomseed((os.epoch and os.epoch("utc") or os.time() * 1000) + os.getComputerID())
  end)
  if not ok then math.randomseed(os.time()) end
end

function M.now()
  if os.epoch then return os.epoch("utc") end
  return os.time() * 1000
end

function M.randomHex(n)
  seed()
  local out = {}
  for i = 1, n do out[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(out)
end

function M.log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local stamp = os.date and os.date("%H:%M:%S") or "?"
  print(("[%s] %s"):format(stamp, table.concat(parts, " ")))
end

function M.ensureDir(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  local current = ""
  for i = 1, #parts do
    current = current .. "/" .. parts[i]
    if not fs.exists(current) then fs.makeDir(current) end
  end
end

function M.readFile(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local data = handle.readAll()
  handle.close()
  return data
end

function M.writeFile(path, data)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then M.ensureDir(dir) end
  local handle = fs.open(path, "wb")
  if not handle then return nil, "cannot open " .. path end
  handle.write(data)
  handle.close()
  return true
end

function M.writeAtomic(path, data)
  local tmp = path .. ".tmp"
  local ok, err = M.writeFile(tmp, data)
  if not ok then return nil, err end
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

function M.append(path, data)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then M.ensureDir(dir) end
  local handle = fs.open(path, "a")
  if not handle then return nil, "cannot open " .. path end
  handle.write(data)
  handle.close()
  return true
end

function M.jsonEncode(value)
  return textutils.serializeJSON(value)
end

function M.jsonDecode(text)
  local ok, value = pcall(textutils.unserializeJSON, text)
  if not ok then return nil end
  return value
end

function M.readJson(path)
  local text = M.readFile(path)
  if not text then return nil end
  return M.jsonDecode(text)
end

function M.writeJson(path, value)
  return M.writeAtomic(path, M.jsonEncode(value))
end

function M.sleep(seconds)
  os.sleep(seconds)
end

return M
