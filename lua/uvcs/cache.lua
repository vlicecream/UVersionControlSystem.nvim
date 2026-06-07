local M = {}

local CACHE_TTL_SECS = 300

local function cache_dir()
  return vim.fn.stdpath("cache") .. "/uvcs"
end

local function cache_file(root)
  return cache_dir() .. "/" .. vim.fn.sha256(tostring(root or "")) .. ".json"
end

function M.load(root)
  local file = cache_file(root)
  local f = io.open(file, "r")
  if not f then
    return nil
  end

  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then
    return nil
  end

  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  if os.time() - tonumber(data.timestamp or 0) > CACHE_TTL_SECS then
    return nil
  end
  return data
end

function M.save(root, data)
  if not root or root == "" or type(data) ~= "table" then
    return
  end

  vim.fn.mkdir(cache_dir(), "p")
  local file = cache_file(root)
  local payload = {
    timestamp = os.time(),
    info = data.info or {},
    counts = {
      opened = tonumber(data.opened_count or 0) or 0,
      local_changes = tonumber(data.local_changes_count or 0) or 0,
      writable = tonumber(data.writable_count or 0) or 0,
      shelved = tonumber(data.shelved_count or 0) or 0,
      pending = tonumber(data.pending_count or 0) or 0,
    },
  }

  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok or not encoded then
    return
  end

  local f = io.open(file, "w")
  if not f then
    return
  end
  f:write(encoded)
  f:close()
end

return M
