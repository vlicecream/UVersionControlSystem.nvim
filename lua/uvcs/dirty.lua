local M = {}

local function normalize(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
end

local function path_under_root(path, root)
  local p = normalize(path)
  local r = normalize(root)
  if not p or not r then
    return false
  end
  p = p:lower()
  r = r:lower()
  if not r:match("/$") then
    r = r .. "/"
  end
  return p:sub(1, #r) == r
end

function M.collect(root)
  local files = {}
  local seen = {}

  if not root or root == "" then
    return files
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local bo = vim.bo[bufnr]
      local path = vim.api.nvim_buf_get_name(bufnr)
      if bo.buflisted and bo.buftype == "" and bo.modified and path ~= "" and path_under_root(path, root) then
        local key = normalize(path):lower()
        if not seen[key] then
          seen[key] = true
          table.insert(files, {
            bufnr = bufnr,
            path = path,
            name = vim.fn.fnamemodify(path, ":."),
          })
        end
      end
    end
  end

  return files
end

local function save_dirty_files(files)
  for _, file in ipairs(files or {}) do
    if vim.api.nvim_buf_is_valid(file.bufnr) and vim.bo[file.bufnr].modified then
      local ok, err = pcall(function()
        vim.api.nvim_buf_call(file.bufnr, function()
          vim.cmd("silent write")
        end)
      end)
      if not ok then
        return false, file.path, err
      end
      if vim.bo[file.bufnr].modified then
        return false, file.path, "buffer is still modified after write"
      end
    end
  end
  return true, nil, nil
end

function M.confirm_save(root, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local files = M.collect(root)
  if #files == 0 then
    callback(true)
    return
  end

  local action = opts.action or "continue"
  local lines = {
    "UVCS found unsaved project files.",
    "",
    tostring(#files) .. " file" .. (#files == 1 and "" or "s") .. " need to be saved before " .. action .. ".",
    "",
  }
  for i, file in ipairs(files) do
    if i > 8 then
      table.insert(lines, "  ...")
      break
    end
    table.insert(lines, "  " .. vim.fn.fnamemodify(file.path, ":."))
  end
  table.insert(lines, "")
  table.insert(lines, "Save all and continue?")

  local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Save all and continue\n&Cancel", 1, "Question")
  if choice ~= 1 then
    callback(false, "cancelled")
    return
  end

  local ok, path, err = save_dirty_files(files)
  if not ok then
    vim.notify(
      "UVCS: failed to save " .. vim.fn.fnamemodify(tostring(path or "?"), ":t") .. "\n" .. tostring(err),
      vim.log.levels.ERROR
    )
    callback(false, err)
    return
  end

  callback(true)
end

return M
