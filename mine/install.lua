-- cc-util starter installer.
--
-- Run on a CC: Tweaked turtle:
--   wget https://github.com/Igidn/cc-util/releases/download/tunnel-latest/install.lua install.lua
--   install
--
-- It generates an ID + secret, registers with the network console through the
-- public tunnel, saves /ccutil/identity.json, downloads the runtime manifest,
-- and installs /startup.lua. No turtle ID is hardcoded anywhere.

local REPO = "Igidn/cc-util"
local TAG = "tunnel-latest"
local BASE = "https://github.com/" .. REPO .. "/releases/download/" .. TAG
local DEST = "/ccutil"
local VERSION = "0.1.0"

local args = { ... }
local override = nil
for i = 1, #args do
  if args[i] == "--url" and args[i + 1] then override = args[i + 1] end
end

local function ensureDir(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  local current = ""
  for i = 1, #parts do
    current = current .. "/" .. parts[i]
    if not fs.exists(current) then fs.makeDir(current) end
  end
end

local function readFile(path)
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "rb")
  if not handle then return nil end
  local data = handle.readAll()
  handle.close()
  return data
end

local function writeFile(path, data)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then ensureDir(dir) end
  local handle = fs.open(path, "wb")
  if not handle then return nil, "cannot open " .. path end
  handle.write(data)
  handle.close()
  return true
end

local function jsonDecode(text)
  local ok, value = pcall(textutils.unserializeJSON, text)
  if not ok then return nil end
  return value
end

local function httpGet(url)
  local response, err = http.get(url, { ["User-Agent"] = "cc-util-installer/" .. VERSION })
  if not response then return nil, err or "http.get failed" end
  local code = response.getResponseCode()
  local body = response.readAll()
  response.close()
  if code ~= 200 then return nil, ("http %d from %s"):format(code, url) end
  return body
end

local function httpPost(url, body)
  local response, err = http.post(url, body, {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "cc-util-installer/" .. VERSION,
  })
  if not response then return nil, err or "http.post failed" end
  local code = response.getResponseCode()
  local text = response.readAll()
  response.close()
  if code ~= 200 then return nil, ("http %d: %s"):format(code, text) end
  return text
end

local function randomHex(n)
  math.randomseed((os.epoch and os.epoch("utc") or os.time() * 1000) + os.getComputerID())
  local out = {}
  for i = 1, n do out[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(out)
end

if not http then
  print("HTTP is disabled on this computer. Enable it in the CC:T config.")
  return
end

print("cc-util installer " .. VERSION)
print("repo: " .. REPO .. "  tag: " .. TAG)

-- Reuse an existing identity if this is a reinstall.
local identity = jsonDecode(readFile(DEST .. "/identity.json") or "") or {}
local id = identity.id
local secret = identity.secret
if type(id) ~= "string" or type(secret) ~= "string" then
  local entropy = randomHex(48)
  id = entropy:sub(1, 16)
  secret = entropy:sub(17, 48)
  print("generated turtle id " .. id)
else
  print("reusing turtle id " .. id)
end

local tunnel = override
if not tunnel then
  local body, err = httpGet(BASE .. "/tunnel.json")
  if not body then
    print("could not read tunnel address: " .. tostring(err))
    print("run the network console first, or pass --url https://<tunnel>")
    return
  end
  local data = jsonDecode(body)
  if type(data) ~= "table" or type(data.url) ~= "string" then
    print("tunnel.json is malformed")
    return
  end
  tunnel = data.url:gsub("/+$", "")
end

print("registering with " .. tunnel)
local payload = textutils.serializeJSON({
  id = id,
  secret = secret,
  computerId = os.getComputerID(),
  label = os.getComputerLabel(),
  version = VERSION,
})
local reply, rerr = httpPost(tunnel .. "/api/register", payload)
if not reply then
  print("registration failed: " .. tostring(rerr))
  return
end
local registered = jsonDecode(reply)
if type(registered) ~= "table" or not registered.ok then
  print("registration rejected: " .. tostring(registered and registered.error or reply))
  return
end

local saved = {
  id = id,
  secret = secret,
  station = registered.station,
  serverUrl = tunnel,
  createdAt = os.epoch and os.epoch("utc") or os.time() * 1000,
  version = VERSION,
}
local ok, werr = writeFile(DEST .. "/identity.json", textutils.serializeJSON(saved))
if not ok then
  print("could not save identity: " .. tostring(werr))
  return
end
writeFile(DEST .. "/id", id .. "\n")
print("station " .. tostring(registered.station and registered.station.id or "?"))

-- Signal the console that this turtle needs a role. The console will show a
-- pending-role prompt; the operator selects station_builder / miner / hauler.
print("requesting role assignment from console...")
local rbody, rerr = httpPost(tunnel .. "/api/turtles/" .. id .. "/role-request", textutils.serializeJSON({
  computerId = os.getComputerID(),
  label = os.getComputerLabel(),
}))
if not rbody then
  print("could not request role: " .. tostring(rerr))
  return
end

-- Block until the console assigns a role (station_builder / miner / hauler).
-- The installer does not proceed to download/reboot until the operator selects
-- a role from the console. Polls every 2 seconds.
print("waiting for console to assign a role...")
local role = nil
local roleDeadline = (os.epoch and os.epoch("utc") or os.time() * 1000) + 300 * 1000 -- 5 min max
while true do
  local now = os.epoch and os.epoch("utc") or os.time() * 1000
  if now > roleDeadline then
    print("timeout waiting for role assignment; aborting install")
    return
  end

  local body, err = httpGet(tunnel .. "/api/turtles/" .. id .. "/role-status")
  if body then
    local data = jsonDecode(body)
    if type(data) == "table" and type(data.role) == "string" and data.role ~= "unassigned" then
      role = data.role
      if type(data.station) == "table" then saved.station = data.station end
      break
    end
  end
  os.sleep(2)
end

print("role assigned: " .. role)
print("station assigned: " .. tostring(saved.station and saved.station.id or "?"))
saved.role = role
writeFile(DEST .. "/identity.json", textutils.serializeJSON(saved))

-- Download the runtime manifest and every listed asset.
local manifestBody, merr = httpGet(BASE .. "/manifest.json")
if not manifestBody then
  print("could not read manifest: " .. tostring(merr))
  return
end
local manifest = jsonDecode(manifestBody)
if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
  print("manifest is malformed")
  return
end

for _, file in ipairs(manifest.files) do
  if type(file.asset) == "string" and type(file.path) == "string" then
    local body, err = httpGet(BASE .. "/" .. file.asset)
    if not body then
      print("download failed for " .. file.asset .. ": " .. tostring(err))
      return
    end
    local wok, ferr = writeFile(DEST .. "/" .. file.path, body)
    if not wok then
      print("write failed for " .. file.path .. ": " .. tostring(ferr))
      return
    end
    print("  " .. file.path)
  end
end

-- Install startup, preserving a non-cc-util startup once.
if fs.exists("/startup.lua") then
  local old = readFile("/startup.lua") or ""
  if not old:find("cc-util", 1, true) and not fs.exists("/startup.lua.bak") then
    fs.copy("/startup.lua", "/startup.lua.bak")
    print("backed up existing startup.lua to startup.lua.bak")
  end
end
writeFile("/startup.lua", "-- cc-util managed startup\nshell.run(\"/ccutil/main.lua\")\n")

print("installed. turtle id: " .. id)
print("rebooting in 3 seconds...")
sleep(3)
os.reboot()
