local M = {}

function M.detail(root, provider, change_num)
  local detail, err = provider.changelist_detail(change_num)
  if not detail then
    vim.notify("UVCS: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local file_rows = {}
  local lines = {
    "UVCS Changelist " .. tostring(detail.number),
    string.rep("─", 60),
    "",
    "Description",
    "  " .. detail.description,
    "",
    "Files",
  }

  for _, f in ipairs(detail.files or {}) do
    local name = vim.fn.fnamemodify(f.path, ":t")
    local dir = vim.fn.fnamemodify(f.path, ":h")
    table.insert(lines, string.format("  %s  %-30s %s", f.status, name, dir))
    table.insert(file_rows, { status = f.status, name = name, path = f.path })
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 60))
  table.insert(lines, " s submit   d diff current file   r revert current file   q close")

  local buf = M.create_detail_buffer(lines, detail.number)

  local state = { buf = buf, root = root, provider = provider, change = detail.number, files = file_rows }

  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "s", function()
    local confirm = vim.fn.confirm(
      "UVCS: submit changelist " .. tostring(detail.number) .. "?", "&Submit\n&Cancel", 2, "Question"
    )
    if confirm ~= 1 then return end
    vim.notify("UVCS: submitting...", vim.log.levels.INFO)
    local ok, err = provider.submit_changelist(detail.number)
    if ok then
      vim.notify("UVCS: submit successful", vim.log.levels.INFO)
      vim.api.nvim_buf_delete(buf, { force = true })
    else
      vim.notify("UVCS: submit failed:\n" .. tostring(err), vim.log.levels.ERROR)
    end
  end, opts)

  vim.keymap.set("n", "d", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
    local text_start = 8
    local idx = cur - text_start + 1
    local f = state.files[idx]
    if not f or idx < 1 or idx > #state.files then
      vim.notify("UVCS: move cursor to a file line", vim.log.levels.INFO)
      return
    end
    local diff_text, diff_err = provider.diff(f.path)
    if diff_err then return vim.notify("UVCS: " .. tostring(diff_err), vim.log.levels.ERROR) end
    if not diff_text or diff_text == "" then
      return vim.notify("UVCS: no diff for " .. f.name, vim.log.levels.INFO)
    end
    vim.cmd("belowright 12new")
    local dbuf = vim.api.nvim_get_current_buf()
    vim.bo[dbuf].buftype = "nofile"
    vim.bo[dbuf].bufhidden = "wipe"
    vim.bo[dbuf].swapfile = false
    vim.bo[dbuf].filetype = "diff"
    vim.api.nvim_buf_set_name(dbuf, "uvcs://vcs/diff/" .. f.name)
    local dl = vim.split(diff_text, "\n", { plain = true })
    table.insert(dl, 1, "Diff: " .. f.path)
    table.insert(dl, 1, "")
    vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, dl)
    vim.bo[dbuf].modified = false
  end, opts)

  vim.keymap.set("n", "r", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
    local text_start = 8
    local idx = cur - text_start + 1
    local f = state.files[idx]
    if not f or idx < 1 or idx > #state.files then
      vim.notify("UVCS: move cursor to a file line", vim.log.levels.INFO)
      return
    end
    local confirm = vim.fn.confirm("UVCS: revert " .. f.name .. "?", "&Revert\n&Cancel", 2, "Question")
    if confirm ~= 1 then return end
    provider.do_revert(f.path)
    vim.notify("UVCS: reverted " .. f.name, vim.log.levels.INFO)
  end, opts)

  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, opts)

  vim.api.nvim_set_current_buf(buf)
end

function M.create_detail_buffer(lines, change_num)
  vim.cmd("belowright 15new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "uvcs-changelist"
  vim.bo[buf].modified = false
  vim.api.nvim_buf_set_name(buf, "uvcs://changelist/" .. tostring(change_num))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.wo[vim.api.nvim_get_current_win()].cursorline = true
  return buf
end

return M
