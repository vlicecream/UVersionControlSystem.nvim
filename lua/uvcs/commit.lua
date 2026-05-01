local project = require("uvcs.project")
local vcs = require("uvcs")

local M = {}

local commit_state = nil

local ns = vim.api.nvim_create_namespace("uvcs_vcs_commit")

local HIGHLIGHTS = {
  UVCSCommitBorder = { fg = "#2aa7ff", bg = "#06121f" },
  UVCSCommitTitle = { fg = "#00d7ff", bold = true },
  UVCSCommitSection = { fg = "#00d7ff", bold = true },
  UVCSCommitMeta = { fg = "#ffd166", bold = true },
  UVCSCommitChecked = { fg = "#d7ffaf", bold = true },
  UVCSCommitUnchecked = { link = "NonText" },
  UVCSCommitStatus = { fg = "#4ec9b0", bold = true },
  UVCSCommitPath = { link = "Function" },
  UVCSCommitMuted = { link = "Comment" },
  UVCSCommitFooterKey = { fg = "#ffd166", bold = true },
}

for name, opts in pairs(HIGHLIGHTS) do
  pcall(vim.api.nvim_set_hl, 0, name, opts)
end

function M.open(root, opts)
  opts = opts or {}
  if not root then
    root = project.find_project_root()
    if not root then
      vim.notify("UVCS: no Unreal project detected", vim.log.levels.ERROR)
      return
    end
  end

  local provider = vcs.detect(root)
  if not provider then
    vim.notify("UVCS: no VCS provider detected for this project", vim.log.levels.WARN)
    return
  end

  local files
  if opts.files then
    files = M.build_files_from_paths(provider, root, opts.files)
  else
    files = M.collect_commit_files(provider, root)
  end

  if not files or #files == 0 then
    vim.notify("UVCS: no changes to commit", vim.log.levels.INFO)
    return
  end

  M.decorate_files(provider, root, files)
  local groups = M.group_files(files)
  local lines, layout = M.build_buffer_lines(provider, root, files, groups)
  local buf, win = M.create_buffer(lines, provider, root, files)

  commit_state = {
    buf = buf,
    win = win,
    root = root,
    provider = provider,
    files = files,
    groups = groups,
    file_lines = layout.file_lines,
    message_start = layout.message_start,
    separator_line = layout.separator_line,
  }

  M.render_footer(buf, win, math.min(vim.o.columns - 8, 120))
  M.apply_highlights(buf)
  M.setup_keymaps(buf)
  pcall(vim.api.nvim_set_current_win, win)
  vim.api.nvim_win_set_cursor(win, { commit_state.message_start + 1, 0 })
  vim.cmd("startinsert!")
end

function M.build_files_from_paths(provider, root, paths)
  local local_path = root:gsub("/", "\\") .. "\\"
  local files = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    local rel = path:lower():gsub(local_path:lower(), "")
    local key = rel:lower()
    if not seen[key] then
      seen[key] = true
      table.insert(files, {
        path = path,
        rel = rel,
        status = "edit",
        checked = true,
        change = "default",
      })
    end
  end
  return files
end

function M.collect_commit_files(provider, root)
  local local_path = root:gsub("/", "\\") .. "\\"

  if provider.name() == "p4" then
    local opened = provider.opened(root)
    local local_changes = provider.status(root)

    local seen = {}
    local files = {}

    for _, f in ipairs(opened or {}) do
      local rel = f.path:lower():gsub(local_path:lower(), "")
      local key = rel:lower()
      if not seen[key] then
        seen[key] = true
        table.insert(files, {
          path = f.path,
          rel = rel,
          status = f.action,
          checked = true,
          depot = f.depot,
          change = f.change or "default",
        })
      end
    end

    for _, f in ipairs(local_changes or {}) do
      local rel = f.path:lower():gsub(local_path:lower(), "")
      local key = rel:lower()
      if not seen[key] then
        seen[key] = true
        table.insert(files, {
          path = f.path,
          rel = rel,
          status = f.status == "open for add" and "add" or f.status,
          checked = false,
          is_local = true,
          change = "local",
        })
      end
    end

    return files
  end

  local st = provider.status(root)
  local files = {}
  for _, f in ipairs(st or {}) do
    local rel = f.path:lower():gsub(local_path:lower(), "")
    table.insert(files, {
      path = f.path,
      rel = rel,
      status = f.status,
      checked = true,
      change = "default",
    })
  end
  return files
end

function M.decorate_files(provider, root, files)
  if provider.name() ~= "p4" then
    return
  end

  local opened = provider.opened(root)
  local by_path = {}
  for _, f in ipairs(opened or {}) do
    if f.path then
      by_path[f.path:gsub("\\", "/"):lower()] = f
    end
  end

  for _, file in ipairs(files or {}) do
    local opened_file = by_path[tostring(file.path or ""):gsub("\\", "/"):lower()]
    if opened_file then
      file.status = opened_file.action or file.status
      file.depot = opened_file.depot
      file.change = opened_file.change or file.change or "default"
      file.is_local = false
    else
      file.change = file.change or (file.is_local and "local" or "default")
    end
  end
end

function M.group_files(files)
  local order = {}
  local groups = {}
  for _, file in ipairs(files or {}) do
    local change = tostring(file.change or "default")
    if change == "" or change == "0" then
      change = "default"
    end
    file.change = change
    if not groups[change] then
      groups[change] = { change = change, files = {} }
      table.insert(order, change)
    end
    table.insert(groups[change].files, file)
  end

  table.sort(order, function(a, b)
    if a == "default" then return true end
    if b == "default" then return false end
    if a == "local" then return false end
    if b == "local" then return true end
    return tostring(a) < tostring(b)
  end)

  local result = {}
  for _, key in ipairs(order) do
    table.insert(result, groups[key])
  end
  return result
end

local function changelist_label(change)
  if change == "default" then
    return "Default changelist"
  end
  if change == "local" then
    return "Local candidates"
  end
  return "Changelist " .. tostring(change)
end

function M.build_buffer_lines(provider, root, files, groups)
  local proj_name = vim.fn.fnamemodify(root, ":t")
  local layout = { file_lines = {} }
  local lines = {
    string.format("P4 | %s", proj_name),
    "",
    "Workspace",
    "  Root: " .. root,
  }

  if provider.name() == "p4" then
    local info, _ = provider.info(root)
    if info then
      table.insert(lines, "  Workspace: " .. tostring(info["client name"] or "?"))
      table.insert(lines, "  User: " .. tostring(info["user name"] or "?"))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Changelists")

  for _, group in ipairs(groups or {}) do
    table.insert(lines, string.format("  %s (%d files)", changelist_label(group.change), #group.files))
    for _, f in ipairs(group.files) do
      local mark = f.checked and "[x]" or "[ ]"
      local tag = f.is_local and "local" or "opened"
      table.insert(lines, string.format("    %s  %-6s %-7s %s", mark, tag, f.status, f.rel))
      layout.file_lines[#lines] = f
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Message:")
  layout.message_start = #lines
  table.insert(lines, "")
  layout.separator_line = #lines + 1
  table.insert(lines, "")
  table.insert(lines, "")
  return lines, layout
end

local COMMIT_FOOTER_ITEMS = {
  { key = "Tab",    label = "toggle" },
  { key = "Ctrl-s", label = "submit" },
  { key = "q",      label = "close" },
}

local COMMIT_FOOTER_SHORT_ITEMS = {
  { key = "Tab",    label = "toggle" },
  { key = "Ctrl-s", label = "submit" },
  { key = "q",      label = "close" },
}

local function build_shortcut_line(width, items, short_items, opts)
  opts = opts or {}
  local padding = opts.padding or 2
  local min_gap = opts.min_gap or 2
  local available = math.max(0, width - padding * 2)

  local active = items
  local spans = {}

  for attempt = 1, 3 do
    local item_texts = {}
    local total_w = 0
    for _, item in ipairs(active) do
      local text = item.key .. " " .. item.label
      table.insert(item_texts, { text = text, w = vim.fn.strdisplaywidth(text), key = item.key })
      total_w = total_w + vim.fn.strdisplaywidth(text)
    end

    local count = #active
    local gaps = math.max(0, count - 1)
    local remaining = available - total_w
    local gap_w = 0

    if remaining >= 0 then
      gap_w = gaps > 0 and math.max(min_gap, math.floor(remaining / gaps)) or 0
      local used = total_w + gap_w * gaps
      local extra = available - used
      local left_pad = math.floor(extra / 2)
      local col = padding + left_pad

      local prefix = string.rep(" ", padding + left_pad)
      local parts = {}
      for _, it in ipairs(item_texts) do
        table.insert(spans, { start = col, finish = col + #it.key })
        table.insert(parts, it.text)
        col = col + it.w + gap_w
      end
      local line = prefix .. table.concat(parts, string.rep(" ", gap_w))
      local suffix = math.max(0, width - vim.fn.strdisplaywidth(line))
      return line .. string.rep(" ", suffix), spans
    end

    if attempt == 1 and short_items then
      active = short_items
    elseif attempt == 2 and min_gap > 1 then
      min_gap = 1
    else
      break
    end
  end

  local fallback = string.rep(" ", padding)
      .. vim.fn.strcharpart(table.concat(vim.tbl_map(function(i) return i.key .. " " .. i.label end, active), " "), 0, math.max(0, width - padding * 2))
  return fallback, {}
end

function M.create_buffer(lines, provider, root, files)
  local width = math.min(vim.o.columns - 8, 120)
  local min_height = math.min(14, math.max(1, vim.o.lines - 6))
  local content_height = #lines + 1
  local height = math.min(vim.o.lines - 6, math.max(min_height, content_height))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "single",
    title = " UVCS Commit ",
    title_pos = "center",
  })

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "uvcs-commit"
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_buf_set_name, buf, "uvcs://commit/" .. tostring(buf))

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:UVCSCommitBorder", { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.b[buf].no_cmp = true
  vim.b[buf].completion = false
  vim.b[buf].blink_cmp_disabled = true

  return buf, win
end

function M.render_footer(buf, win, width)
  if not commit_state then return end
  local line, spans = build_shortcut_line(width, COMMIT_FOOTER_ITEMS, COMMIT_FOOTER_SHORT_ITEMS, {
    padding = 4, min_gap = 2,
  })
  if commit_state.separator_line then
    vim.api.nvim_buf_set_lines(buf, commit_state.separator_line - 1, commit_state.separator_line, false, {
      string.rep("-", math.max(1, width)),
    })
  end
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, last - 1, last, false, { line })
  commit_state.footer_line = last
  commit_state.footer_spans = spans
end

function M.get_file_at_line(buf, line)
  if not commit_state then return nil end
  return commit_state.file_lines[line], line
end

function M.is_file_line(buf, line)
  if not commit_state then return false end
  return commit_state.file_lines[line] ~= nil
end

function M.is_message_line(buf, line)
  if not commit_state then return false end
  return line >= (commit_state.message_start + 1)
      and line < commit_state.separator_line
end

function M.apply_highlights(buf)
  if not commit_state then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if i == 1 then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitTitle", lnum, 0, -1)
    elseif line == "Workspace" or line == "Changelists" or line == "Message:" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitSection", lnum, 0, -1)
    elseif line:match("^%s+Root:") or line:match("^%s+Workspace:") or line:match("^%s+User:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitMuted", lnum, 0, -1)
    elseif line:match("^%s+Default changelist") or line:match("^%s+Changelist") or line:match("^%s+Local candidates") then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitMeta", lnum, 0, -1)
    elseif commit_state.file_lines[i] then
      local mark = line:find("%[.%]")
      if mark then
        local file = commit_state.file_lines[i]
        vim.api.nvim_buf_add_highlight(buf, ns, file.checked and "UVCSCommitChecked" or "UVCSCommitUnchecked", lnum, mark - 1, mark + 2)
      end
      local file = commit_state.file_lines[i]
      local status_start = line:find(tostring(file.status or ""), 1, true)
      if status_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitStatus", lnum, status_start - 1, status_start - 1 + #tostring(file.status))
      end
      local rel_start = line:find(file.rel, 1, true)
      if rel_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitPath", lnum, rel_start - 1, -1)
      end
    elseif commit_state.footer_line and i == commit_state.footer_line then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitMuted", lnum, 0, -1)
      for _, span in ipairs(commit_state.footer_spans or {}) do
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSCommitFooterKey", lnum, span.start, span.finish)
      end
    end
  end
end

function M.toggle_file(buf)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_file_line(buf, cur_line) then
    vim.notify("UVCS: move cursor to a file line to toggle", vim.log.levels.INFO)
    return
  end

  local file = M.get_file_at_line(buf, cur_line)
  if not file then return end

  file.checked = not file.checked
  local mark = file.checked and "[x]" or "[ ]"
  local line_content = vim.api.nvim_buf_get_lines(buf, cur_line - 1, cur_line, false)[1] or ""
  local new_line = line_content:gsub("%[.%]", mark)
  vim.api.nvim_buf_set_lines(buf, cur_line - 1, cur_line, false, { new_line })
  M.apply_highlights(buf)
end

function M.add_file(buf)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_file_line(buf, cur_line) then
    vim.notify("UVCS: move cursor to a local file to add", vim.log.levels.INFO)
    return
  end

  local file = M.get_file_at_line(buf, cur_line)
  if not file then return end

  if not file.is_local then
    vim.notify("UVCS: file is already opened in P4", vim.log.levels.INFO)
    return
  end

  local provider = commit_state.provider
  if provider.name() == "p4" then
    local ok, err = provider.add_file(file.path, commit_state.root)
    if ok then
      file.is_local = false
      file.checked = true
      file.status = "add"
      file.change = "default"
      local new_line = string.format("    [x]  opened %-7s %s", "add", file.rel)
      vim.api.nvim_buf_set_lines(buf, cur_line - 1, cur_line, false, { new_line })
      M.apply_highlights(buf)
      vim.notify("UVCS: p4 add " .. vim.fn.fnamemodify(file.path, ":t"), vim.log.levels.INFO)
    else
      vim.notify("UVCS: p4 add failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  else
    vim.notify("UVCS: add is not implemented for " .. provider.name():upper(), vim.log.levels.INFO)
  end
end

function M.get_message(buf)
  if not commit_state then return "" end
  local start = commit_state.message_start + 1
  local end_line = commit_state.separator_line - 1
  local total = vim.api.nvim_buf_line_count(buf)
  end_line = math.min(end_line, total)

  if start > end_line then return "" end

  local msg_lines = vim.api.nvim_buf_get_lines(buf, start - 1, end_line, false)
  local msg = {}
  for _, l in ipairs(msg_lines) do
    table.insert(msg, l)
  end
  return table.concat(msg, "\n"):gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
end

function M.get_checked_files(buf)
  if not commit_state then return {} end
  local checked = {}
  for _, f in ipairs(commit_state.files) do
    if f.checked then
      table.insert(checked, f)
    end
  end
  return checked
end

function M.get_checked_changelists(files)
  local groups = {}
  for _, f in ipairs(files or {}) do
    local change = tostring(f.change or "default")
    groups[change] = groups[change] or {}
    table.insert(groups[change], f)
  end
  return groups
end

function M.submit(buf, skip_dirty_check)
  if not commit_state then return end

  if not skip_dirty_check then
    local root = commit_state.root
    require("uvcs.dirty").confirm_save(root, { action = "commit" }, function(ok)
      if ok then
        M.submit(buf, true)
      end
    end)
    return
  end

  local message = M.get_message(buf)
  if message == "" then
    vim.notify("UVCS: commit message is required", vim.log.levels.WARN)
    return
  end

  local checked = M.get_checked_files(buf)
  if #checked == 0 then
    vim.notify("UVCS: no files selected for commit", vim.log.levels.WARN)
    return
  end

  local checked_groups = M.get_checked_changelists(checked)
  local group_names = vim.tbl_keys(checked_groups)
  table.sort(group_names)

  local summary_lines = {"Submit to " .. commit_state.provider.name():upper() .. "?", "", "Changelists:"}
  for _, change in ipairs(group_names) do
    table.insert(summary_lines, "- " .. changelist_label(change) .. " (" .. tostring(#checked_groups[change]) .. " files)")
  end
  table.insert(summary_lines, "")
  table.insert(summary_lines, "Files:")
  for _, f in ipairs(checked) do
    table.insert(summary_lines, "- " .. f.status .. " " .. f.rel)
  end
  table.insert(summary_lines, "")
  table.insert(summary_lines, "Message:")
  local msg_preview = message:gsub("\n", " "):sub(1, 80)
  table.insert(summary_lines, msg_preview)
  table.insert(summary_lines, "")
  table.insert(summary_lines, "Proceed?")

  local confirm = vim.fn.confirm(
    table.concat(summary_lines, "\n"),
    "&Yes\n&No",
    2,
    "Question"
  )
  if confirm ~= 1 then
    return
  end

  vim.notify("UVCS: submitting...", vim.log.levels.INFO)

  local ok, err
  if commit_state.provider.name() == "p4" and #group_names == 1 and group_names[1] ~= "default" and group_names[1] ~= "local" then
    ok, err = commit_state.provider.submit_changelist(group_names[1])
  else
    local file_paths = vim.tbl_map(function(f) return f.path end, checked)
    ok, err = commit_state.provider.commit(commit_state.root, file_paths, message, {})
  end

  if ok then
    vim.notify("UVCS: submit successful", vim.log.levels.INFO)
    vim.api.nvim_buf_delete(buf, { force = true })
    commit_state = nil
  else
    local err_text = tostring(err)
    local change_hint = ""
    local change_num = err_text:match("Change (%d+)")
    if change_num then
      change_hint = "\nChangelist " .. change_num .. " was kept.\nRun :UVCS changelists"
    end
    vim.notify("UVCS: submit failed:\n" .. err_text .. change_hint, vim.log.levels.ERROR)
    vim.bo[buf].modified = true
  end
end

function M.diff_file(buf)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_file_line(buf, cur_line) then
    vim.notify("UVCS: move cursor to a file line to diff", vim.log.levels.INFO)
    return
  end
  local file = M.get_file_at_line(buf, cur_line)
  if not file then return end

  local provider = commit_state.provider
  local diff_text, diff_err = provider.diff(file.path, commit_state.root)
  if diff_err then
    vim.notify("UVCS: diff failed: " .. tostring(diff_err), vim.log.levels.ERROR)
    return
  end
  if not diff_text or diff_text == "" then
    vim.notify("UVCS: no diff for " .. vim.fn.fnamemodify(file.path, ":t"), vim.log.levels.INFO)
    return
  end

  vim.cmd("botright 12new")
  local dbuf = vim.api.nvim_get_current_buf()
  vim.bo[dbuf].buftype = "nofile"
  vim.bo[dbuf].bufhidden = "wipe"
  vim.bo[dbuf].swapfile = false
  vim.bo[dbuf].filetype = "diff"
  pcall(vim.api.nvim_buf_set_name, dbuf, "uvcs://diff/" .. vim.fn.fnamemodify(file.path, ":t"))

  local diff_lines = vim.split(diff_text, "\n", { plain = true })
  local header = "--- a/" .. file.rel
  local header2 = "+++ b/" .. file.rel
  table.insert(diff_lines, 1, header2)
  table.insert(diff_lines, 1, header)
  vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, diff_lines)
  vim.bo[dbuf].modified = false
end

function M.revert_file(buf)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_file_line(buf, cur_line) then
    vim.notify("UVCS: move cursor to a file line to revert", vim.log.levels.INFO)
    return
  end
  local file = M.get_file_at_line(buf, cur_line)
  if not file then return end

  local confirm = vim.fn.confirm(
    "UVCS: revert " .. vim.fn.fnamemodify(file.path, ":t") .. "?\n\nThis discards local changes.",
    "&Revert\n&Cancel",
    2,
    "Question"
  )
  if confirm ~= 1 then return end

  local provider = commit_state.provider
  if provider.name() == "p4" then
    local ok, err = provider.do_revert(file.path, commit_state.root)
    if ok then
      vim.notify("UVCS: reverted " .. vim.fn.fnamemodify(file.path, ":t"), vim.log.levels.INFO)
    else
      vim.notify("UVCS: revert failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  else
    vim.notify("UVCS: revert is not implemented for " .. provider.name():upper(), vim.log.levels.INFO)
  end

  vim.api.nvim_buf_delete(buf, { force = true })
  commit_state = nil
end

function M.close(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  commit_state = nil
end

function M.setup_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Tab>", function()
    M.toggle_file(buf)
  end, opts)

  vim.keymap.set("i", "<Tab>", function()
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    if M.is_file_line(buf, cur_line) then
      M.toggle_file(buf)
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
    end
  end, opts)

  vim.keymap.set("n", "<C-s>", function()
    M.submit(buf)
  end, opts)

  vim.keymap.set("i", "<C-s>", function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    M.submit(buf)
  end, opts)

  vim.keymap.set("n", "q", function()
    M.close(buf)
  end, opts)
end

return M
