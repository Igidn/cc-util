local util = require("lib.util")

local M = {}
M.path = "/ccutil/identity.json"

function M.load()
  local data = util.readJson(M.path)
  if type(data) == "table" and type(data.id) == "string" and type(data.secret) == "string" then
    return data
  end
  return nil
end

function M.save(id, secret, station, serverUrl)
  local data = {
    id = id,
    secret = secret,
    station = station,
    serverUrl = serverUrl,
    createdAt = util.now(),
    version = util.VERSION,
  }
  local ok, err = util.writeJson(M.path, data)
  if not ok then return nil, err end
  util.writeFile("/ccutil/id", id .. "\n")
  return data
end

return M