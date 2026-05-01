local project = require("uvcs.project")
local p4 = require("uvcs.p4")

local M = {}

local state = nil
local ns = vim.api.nvim_create_namespace("uvcs_vcs_dashboard")
local autocmd_group = nil

local HIGHLIGHTS = {
  UVCSVcsBorder = { fg = "#2aa7ff", bg = "#06121f" },
  UVCSVcsTitle = { fg = "#00d7ff", bold = true },
  UVCSVcsHeader = { link = "NormalFloat" },
  UVCSVcsProvider = { fg = "#7ee787", bold = true },
  UVCSVcsProject = { fg = "#7ee787", bold = true },
  UVCSVcsMeta = { fg = "#ffd166", bold = true },
  UVCSVcsSection = { fg = "#00d7ff", bold = true },
  UVCSVcsSelected = { fg = "#fff2a8", bg = "#5c5200", bold = true },
  UVCSVcsSelector = { fg = "#ffd166", bg = "#5c5200", bold = true },
  UVCSVcsChecked = { fg = "#d7ffaf", bold = true },
  UVCSVcsUnchecked = { link = "NonText" },
  UVCSVcsStatusEdit = { fg = "#4ec9b0" },
  UVCSVcsStatusAdd = { fg = "#6a9955" },
  UVCSVcsStatusDel = { fg = "#f14c4c" },
  UVCSVcsStatusLocal = { fg = "#dcdcaa" },
  UVCSVcsFilename = { link = "Function" },
  UVCSVcsDir = { link = "Comment" },
  UVCSVcsChangelistNum = { link = "Number" },
  UVCSVcsChangelistDesc = { link = "String" },
  UVCSVcsHelp = { link = "NonText" },
  UVCSVcsMuted = { link = "Comment" },
  UVCSVcsFooterKey = { fg = "#ffd166", bold = true },
  UVCSVcsDiffAdd = { fg = "#7ee787" },
  UVCSVcsDiffDel = { fg = "#ff6b6b" },
  UVCSVcsDiffHunk = { fg = "#58a6ff" },
  UVCSVcsFoldOpen = { fg = "#ffd166", bold = true },
  UVCSVcsFoldClosed = { fg = "#7ee787", bold = true },
  UVCSVcsGroupTitle = { fg = "#00d7ff", bold = true },
}

for name, opts in pairs(HIGHLIGHTS) do
  pcall(vim.api.nvim_set_hl, 0, name, opts)
end

local function split_path(path)
  local name = vim.fn.fnamemodify(path, ":t")
  local dir = vim.fn.fnamemodify(path, ":h")
  return name, dir
end

local function normalize_path(path)
  return tostring(path or ""):gsub("\\", "/")
end

local function compact_directory(path, width)
  path = normalize_path(path)
  width = width or 28
  if path == "" then
    return ""
  end

  local root = state and state.root and normalize_path(state.root) or ""
  if root ~= "" and path:lower():sub(1, #root) == root:lower() then
    path = path:sub(#root + 2)
  end

  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end

  local tail = path:sub(math.max(1, #path - width + 4))
  return "..." .. tail
end

local function file_status_label(raw_status)
  if raw_status == "open for add" or raw_status == "add" or raw_status == "a" or raw_status == "?" then
    return "add?"
  end
  return "modify?"
end

local function is_add_candidate(item)
  return item and item.kind == "file" and item.section == "local" and item.status == "add?"
end

local function is_modify_candidate(item)
  return item and item.kind == "file" and item.section == "local" and item.status == "modify?"
end

local function is_dashboard_file(path)
  return p4.is_project_file(path, state and state.root or nil)
end

local function should_show(section)
  if not state then
    return true
  end
  local filter = state.filter or "all"
  if filter == "files" then
    return section == "files" or section == "writable"
  end
  if filter == "shelved" then
    return section == "shelved"
  end
  return true
end

local function count_values(values)
  return type(values) == "table" and #values or 0
end

local group_opened_by_changelist

local function section_count(section)
  if not state then
    return "0"
  end
  if state.loading[section] then
    return "..."
  end
  if state.data.errors[section] then
    return "err"
  end
  if section == "info" then
    return "1"
  end
  if section == "shelved" then
    return tostring(count_values(state.data.shelved)) .. " shelves"
  end
  if section == "files" then
    local groups = group_opened_by_changelist(state.data.opened)
    local count = 0
    for _, files in pairs(groups) do
      count = count + #files
    end
    return tostring(count + count_values(state.data.local_changes))
  end
  if section == "writable" then
    return tostring(count_values(state.data.writable_unopened))
  end
  return "0"
end

local function count_section(section)
  return section_count(section)
end

local function is_selectable(row)
  return row and (row.kind == "file" or row.kind == "changelist" or row.kind == "shelved" or row.kind == "changelist_header" or row.kind == "shelf_header")
end

local function normalize_change_id(change)
  change = vim.trim(tostring(change or ""))
  if change == "" or change == "0" then
    return "default"
  end

  local lowered = change:lower()
  if lowered == "default" or lowered == "default change" then
    return "default"
  end

  return lowered:match("^change%s+(%d+)$") or lowered:match("^(%d+)%s+change$") or change
end

group_opened_by_changelist = function(opened)
  local groups = {}
  for _, file in ipairs(opened or {}) do
    local change = normalize_change_id(file.change)
    file.change = change
    groups[change] = groups[change] or {}
    table.insert(groups[change], file)
  end
  return groups
end

local function clean_description(desc)
  desc = tostring(desc or ""):gsub("\r", " "):gsub("\n", " ")
  desc = vim.trim(desc)
  if desc == "" then
    return ""
  end
  return desc
end

local function pending_description(change)
  change = normalize_change_id(change)
  if not state or change == "default" then
    return "Default changelist"
  end
  for _, ch in ipairs(state.data.pending or {}) do
    if tostring(ch.number) == tostring(change) then
      local desc = clean_description(ch.description)
      if desc ~= "" then
        return desc
      end
      break
    end
  end
  return "Change " .. tostring(change)
end

local function trim_display(text, max_width)
  text = tostring(text or "")
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, max_width - 1)) .. "…"
end

local function loading_message(section)
  if not state or not state.loading[section] then
    return nil
  end
  if section == "info" then
    return "  (workspace loading...)"
  end
  if section == "files" then
    return "  (changes loading...)"
  end
  if section == "writable" then
    return "  (scanning writable files...)"
  end
  if section == "shelved" then
    return "  (shelved changelists loading...)"
  end
  return "  (loading...)"
end

local function error_message(section)
  if not state then
    return nil
  end
  local err = state.data.errors[section]
  if not err then
    return nil
  end
  return "  (" .. tostring(err) .. ")"
end

local function rebuild_rows()
  if not state then
    return
  end

  local data = state.data
  local rows = {}
  table.insert(rows, { kind = "section", label = "Workspace" })
  table.insert(rows, { kind = "info", label = "Root", value = state.root })

  if state.loading.info then
    table.insert(rows, { kind = "empty", text = loading_message("info") })
  elseif data.errors.info then
    table.insert(rows, { kind = "empty", text = error_message("info") })
  else
    table.insert(rows, { kind = "info", label = "Workspace", value = data.info["client name"] or "?" })
    table.insert(rows, { kind = "info", label = "User", value = data.info["user name"] or "?" })
  end

  if should_show("files") then
    table.insert(rows, { kind = "blank" })
    table.insert(rows, { kind = "section", label = "Workspace Changes" })
    if state.loading.files then
      table.insert(rows, { kind = "empty", text = loading_message("files") })
    elseif data.errors.files then
      table.insert(rows, { kind = "empty", text = error_message("files") })
    else
      local groups = group_opened_by_changelist(data.opened)
      local change_order = {}
      for k in pairs(groups) do
        table.insert(change_order, k)
      end
      table.sort(change_order, function(a, b)
        if a == "default" then return true end
        if b == "default" then return false end
        local na = tonumber(a) or 0
        local nb = tonumber(b) or 0
        return na < nb
      end)

      local has_changes = false
      for _, change in ipairs(change_order) do
        local files = groups[change]
        local expanded = state.expanded.changelists[change]
        if expanded == nil then
          expanded = change == "default"
          state.expanded.changelists[change] = expanded
        end
        local desc = pending_description(change)
        has_changes = true
        local fold = expanded and "▾" or "▸"
        local display_name = trim_display(desc, 50)
        local header_text = string.format("%s %s (%d files)", fold, display_name, #files)
        table.insert(rows, {
          kind = "changelist_header",
          change = change,
          expanded = expanded,
          file_count = #files,
          description = desc,
          text = header_text,
        })
        if expanded then
          table.sort(files, function(a, b)
            local pa = p4.normalize_local_file(a.path, state.root) or a.path or ""
            local pb = p4.normalize_local_file(b.path, state.root) or b.path or ""
            return pa:lower() < pb:lower()
          end)
          for _, f in ipairs(files) do
            local file_path = p4.normalize_local_file(f.path, state.root)
            if file_path then
              local name, dir = split_path(file_path)
              table.insert(rows, {
                kind = "file",
                section = "opened",
                checked = true,
                status = f.action,
                raw_status = f.action,
                path = file_path,
                filename = name,
                directory = dir,
                change = change,
              })
            end
          end
        end
      end

      if count_values(data.local_changes) > 0 then
        local local_expanded = state.expanded.changelists["local"]
        if local_expanded == nil then
          local_expanded = true
          state.expanded.changelists["local"] = true
        end
        has_changes = true
        local fold = local_expanded and "▾" or "▸"
        table.insert(rows, {
          kind = "changelist_header",
          change = "local",
          expanded = local_expanded,
          file_count = count_values(data.local_changes),
          description = "Local candidates",
          text = string.format("%s Local candidates (%d files)", fold, count_values(data.local_changes)),
        })
        if local_expanded then
          for _, f in ipairs(data.local_changes or {}) do
            local file_path = p4.normalize_local_file(f.path, state.root)
            if file_path then
              local name, dir = split_path(file_path)
              table.insert(rows, {
                kind = "file",
                section = "local",
                checked = false,
                status = file_status_label(f.status),
                raw_status = f.status,
                path = file_path,
                filename = name,
                directory = dir,
              })
            end
          end
        end
      end

      if not has_changes then
        table.insert(rows, { kind = "empty", text = "  (no changes)" })
      end
    end
  end

  if should_show("writable") then
    table.insert(rows, { kind = "blank" })
    table.insert(rows, { kind = "section", label = "Writable Files" })
    if state.loading.writable then
      table.insert(rows, { kind = "empty", text = loading_message("writable") })
    elseif data.errors.writable then
      table.insert(rows, { kind = "empty", text = error_message("writable") })
    elseif count_values(data.writable_unopened) > 0 then
      for _, f in ipairs(data.writable_unopened or {}) do
        local file_path = p4.normalize_local_file(f.path, state.root)
        if file_path then
          local name, dir = split_path(file_path)
          table.insert(rows, {
            kind = "file",
            section = "writable",
            checked = false,
            status = "writable?",
            raw_status = f.status,
            path = file_path,
            filename = name,
            directory = dir,
          })
        end
      end
    else
      table.insert(rows, { kind = "empty", text = "  (none)" })
    end
  end

  if should_show("shelved") then
    table.insert(rows, { kind = "blank" })
    table.insert(rows, { kind = "section", label = "Shelves" })
    if state.loading.shelved then
      table.insert(rows, { kind = "empty", text = loading_message("shelved") })
    elseif data.errors.shelved then
      table.insert(rows, { kind = "empty", text = error_message("shelved") })
    elseif count_values(data.shelved) > 0 then
      for _, ch in ipairs(data.shelved) do
        local key = tostring(ch.number)
        local expanded = state.expanded.shelves[key]
        if expanded == nil then
          expanded = false
          state.expanded.shelves[key] = false
        end
        local fold = expanded and "▾" or "▸"
        local file_count = 0
        local count_known = false
        local cached = state.data.shelf_files[key]
        if cached then
          if type(cached.files) == "table" and #cached.files > 0 then
            file_count = #cached.files
            count_known = true
          elseif cached.lazy_count and cached.lazy_count > 0 then
            file_count = cached.lazy_count
            count_known = true
          end
        end
        local display_name = tostring(ch.description or ""):gsub("\n", " "):sub(1, 40)
        if #display_name == 0 then
          display_name = "<no description>"
        end
        local count_str = count_known and " (" .. tostring(file_count) .. " file" .. (file_count ~= 1 and "s" or "") .. ")" or ""
        if expanded and not cached then
          count_str = ""
        end
        local header_text = string.format("%s %s%s                  CL %d", fold, display_name, count_str, ch.number)
        table.insert(rows, {
          kind = "shelf_header",
          number = ch.number,
          expanded = expanded,
          file_count = file_count,
          description = display_name,
          user = ch.user,
          text = header_text,
        })
        if expanded then
          local cached = state.data.shelf_files[key]
          if cached and type(cached.files) == "table" then
            for _, f in ipairs(cached.files) do
              local file_path = f.path
              -- convert depot path to local
              if file_path:match("^//") then
                file_path = file_path:gsub("#%d+$", "")
                local local_p = p4.depot_to_local(file_path)
                if local_p then
                  file_path = local_p
                end
              end
              local name, dir = split_path(file_path)
              local action = f.status or f.action or "edit"
              table.insert(rows, {
                kind = "file",
                section = "shelf",
                checked = false,
                status = "shelved/" .. action:lower(),
                raw_status = action,
                path = file_path,
                filename = name ~= file_path and name or file_path,
                directory = dir ~= file_path and dir or "",
                shelf_number = ch.number,
              })
            end
          else
            table.insert(rows, { kind = "empty", text = "  (loading...)" })
          end
        end
      end
    else
      table.insert(rows, { kind = "empty", text = "  (none)" })
    end
  end

  state.rows = rows
end

local function cursor_to_first_selectable()
  if not state then return end
  for _, kind in ipairs({ "changelist_header", "shelf_header", "file", "changelist", "shelved" }) do
    for i, row in ipairs(state.rows) do
      if row.kind == kind then
        state.cursor = i
        return
      end
    end
  end
  state.cursor = 1
end

local function get_current_item()
  if not state then return nil end
  return state.rows[state.cursor]
end

local function find_loaded_buffer(path)
  if not path or path == "" then
    return nil
  end
  local target = normalize_path(path):lower()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      if buf_path ~= "" and normalize_path(buf_path):lower() == target then
        return bufnr
      end
    end
  end
  return nil
end

local function reload_buffer_from_disk(path)
  local bufnr = find_loaded_buffer(path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! edit!")
  end)
end

local function move_cursor(delta)
  if not state then return end
  local n = #state.rows
  local pos = state.cursor
  for _ = 1, n do
    pos = ((pos - 1 + delta) % n + n) % n + 1
    if is_selectable(state.rows[pos]) then
      break
    end
  end
  if is_selectable(state.rows[pos]) then
    state.cursor = pos
    M.render_left()
    M.render_right()
    M.render_footer()
  end
end

local function will_fit()
  return vim.o.columns >= 82 and vim.o.lines >= 24
end

local function open_windows()
  if not will_fit() then
    vim.notify("UVCS: terminal too small for dashboard", vim.log.levels.WARN)
    return false
  end

  local ed_w = vim.o.columns
  local ed_h = vim.o.lines
  local total_w = ed_w - 4
  local left_w = math.max(42, math.floor(total_w * 0.37))
  local gap = 2
  local right_w = total_w - left_w - gap
  if right_w < 30 then
    left_w = total_w - 34
    right_w = 30
  end

  local h = ed_h - 4
  local row = 1
  local col = math.max(0, math.floor((ed_w - total_w) / 2))
  local header_h = 1
  local footer_h = 1
  local main_row = row + header_h + 2
  local footer_row = row + h - footer_h - 2
  local list_h = math.max(10, footer_row - main_row - 1)

  local success, result = pcall(function()
    local header_buf = vim.api.nvim_create_buf(false, true)
    local header_win = vim.api.nvim_open_win(header_buf, false, {
      relative = "editor",
      width = total_w,
      height = header_h,
      row = row,
      col = col,
      style = "minimal",
      border = "single",
    })
    vim.bo[header_buf].modifiable = true

    local left_buf = vim.api.nvim_create_buf(false, true)
    local left_win = vim.api.nvim_open_win(left_buf, true, {
      relative = "editor",
      width = left_w,
      height = list_h,
      row = main_row,
      col = col,
      style = "minimal",
      border = "single",
    })
    vim.bo[left_buf].modifiable = true
    vim.wo[left_win].cursorline = false
    vim.wo[left_win].cursorlineopt = "line"

    local right_buf = vim.api.nvim_create_buf(false, true)
    local right_win = vim.api.nvim_open_win(right_buf, false, {
      relative = "editor",
      width = right_w,
      height = list_h,
      row = main_row,
      col = col + left_w + gap,
      style = "minimal",
      border = "single",
    })
    vim.bo[right_buf].modifiable = true

    local footer_buf = vim.api.nvim_create_buf(false, true)
    local footer_win = vim.api.nvim_open_win(footer_buf, false, {
      relative = "editor",
      width = total_w,
      height = footer_h,
      row = footer_row,
      col = col,
      style = "minimal",
      border = "single",
    })
    vim.bo[footer_buf].modifiable = true

    local winhl = "Normal:NormalFloat,FloatBorder:UVCSVcsBorder"
    vim.api.nvim_set_option_value("winhl", winhl, { win = header_win })
    vim.api.nvim_set_option_value("winhl", winhl, { win = left_win })
    vim.api.nvim_set_option_value("winhl", winhl, { win = right_win })
    vim.api.nvim_set_option_value("winhl", winhl, { win = footer_win })

    return {
      header_buf = header_buf, header_win = header_win,
      left_buf = left_buf, left_win = left_win,
      right_buf = right_buf, right_win = right_win,
      footer_buf = footer_buf, footer_win = footer_win,
    }
  end)

  if not success then
    vim.notify("UVCS: failed to create windows: " .. tostring(result), vim.log.levels.ERROR)
    return nil
  end

  return result
end

function M.close()
  if not state then return end
  if autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, autocmd_group)
    autocmd_group = nil
  end
  if state.wins then
    local w = state.wins
    pcall(vim.api.nvim_win_close, w.header_win, true)
    pcall(vim.api.nvim_win_close, w.left_win, true)
    pcall(vim.api.nvim_win_close, w.right_win, true)
    pcall(vim.api.nvim_win_close, w.footer_win, true)
    pcall(vim.api.nvim_buf_delete, w.header_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, w.left_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, w.right_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, w.footer_buf, { force = true })
  end
  state = nil
end

local function render_status_text()
  if not state then
    return "closed"
  end
  if state.status and state.status ~= "" then
    return state.status
  end
  if state.loading.info then return "loading workspace..." end
  if state.loading.files then return "loading changes..." end
  if state.loading.shelved then return "loading shelved..." end
  return "ready"
end

local DASHBOARD_FOOTER_ITEMS = {
  { key = "j/k",    label = "move" },
  { key = "Space",  label = "toggle" },
  { key = "Enter",  label = "open" },
  { key = "d",      label = "diff" },
  { key = "c",      label = "checkout" },
  { key = "a",      label = "add" },
  { key = "r",      label = "revert" },
  { key = "m",      label = "commit" },
  { key = "R",      label = "refresh" },
  { key = "q",      label = "close" },
}

local DASHBOARD_FOOTER_SHORT_ITEMS = {
  { key = "j/k", label = "move" },
  { key = "d",   label = "diff" },
  { key = "m",   label = "commit" },
  { key = "R",   label = "refresh" },
  { key = "q",   label = "close" },
}

local function footer_items_for_current()
  local item = get_current_item()
  if item and item.kind == "file" and item.section == "writable" then
    return vim.tbl_filter(function(entry)
      return entry.key ~= "r"
    end, DASHBOARD_FOOTER_ITEMS)
  end
  return DASHBOARD_FOOTER_ITEMS
end

local function footer_short_items_for_current()
  local item = get_current_item()
  if item and item.kind == "file" and item.section == "writable" then
    return vim.tbl_filter(function(entry)
      return entry.key ~= "r"
    end, DASHBOARD_FOOTER_SHORT_ITEMS)
  end
  return DASHBOARD_FOOTER_SHORT_ITEMS
end

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

local function pad_to_width(text, width)
  local pad = width - vim.fn.strdisplaywidth(text)
  if pad <= 0 then
    return text
  end
  return text .. string.rep(" ", pad)
end

local HEADER_PADDING = 2

local function compose_header(left, center, right, width)
  local inner_width = math.max(1, width - HEADER_PADDING * 2)
  local left_w = vim.fn.strdisplaywidth(left)
  local center_w = vim.fn.strdisplaywidth(center)
  local right_w = vim.fn.strdisplaywidth(right)
  if left_w + center_w + right_w + 4 > inner_width then
    center = "UVCS"
    center_w = vim.fn.strdisplaywidth(center)
  end

  local center_col = math.max(left_w + 2, math.floor((inner_width - center_w) / 2))
  local right_col = math.max(center_col + center_w + 2, inner_width - right_w)
  local line = " " .. left
  line = pad_to_width(line, center_col)
  line = line .. center
  line = pad_to_width(line, right_col)
  line = line .. right
  local composed_width = vim.fn.strdisplaywidth(line)
  local right_padding = math.max(0, inner_width - composed_width)
  return string.rep(" ", HEADER_PADDING) .. line .. string.rep(" ", HEADER_PADDING + right_padding)
end

local function add_pattern_highlight(buf, line, text, pattern, group)
  local start_col = text:find(pattern, 1, true)
  if start_col then
    vim.api.nvim_buf_add_highlight(buf, ns, group, line, start_col - 1, start_col - 1 + #pattern)
  end
end

function M.render_header()
  if not state or not state.wins then return end
  local buf = state.wins.header_buf
  vim.bo[buf].modifiable = true
  local info = state.data.info or {}
  local workspace = info["client name"] or "?"
  local user = info["user name"] or "?"
  local left = string.format("P4 | %s", state.project_name or "?")
  local center = "UVCS"
  local right = string.format("Workspace: %s | User: %s", workspace, user)
  local width = vim.api.nvim_win_get_width(state.wins.header_win)
  local line = compose_header(left, center, right, width)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  add_pattern_highlight(buf, 0, line, "P4", "UVCSVcsProvider")
  add_pattern_highlight(buf, 0, line, state.project_name or "?", "UVCSVcsProject")
  add_pattern_highlight(buf, 0, line, center, "UVCSVcsTitle")
  add_pattern_highlight(buf, 0, line, "Workspace:", "UVCSVcsMeta")
  add_pattern_highlight(buf, 0, line, "User:", "UVCSVcsMeta")
  vim.bo[buf].modifiable = false
end

function M.render_footer()
  if not state or not state.wins or not state.wins.footer_buf then return end
  local buf = state.wins.footer_buf
  local width = vim.api.nvim_win_get_width(state.wins.footer_win)
  local line, spans = build_shortcut_line(width, footer_items_for_current(), footer_short_items_for_current(), {
    padding = 4, min_gap = 2,
  })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsHelp", 0, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsFooterKey", 0, span.start, span.finish)
  end
  vim.bo[buf].modifiable = false
end

function M.render_left()
  if not state or not state.wins then return end
  local buf = state.wins.left_buf
  local rows = state.rows
  local win_width = vim.api.nvim_win_get_width(state.wins.left_win)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local text_lines = {}
  for i, row in ipairs(rows) do
    local selected = i == state.cursor and is_selectable(row)
    local pointer = selected and "> " or "  "
    if row.kind == "section" then
      local label = row.label
      local suffix = ""
      if label == "Workspace Changes" then
        suffix = section_count("files") .. " files"
      elseif label == "Writable Files" then
        suffix = section_count("writable") .. " files"
      elseif label == "Pending Changelists" then
        suffix = section_count("pending") .. " changelists"
      elseif label == "Shelves" then
        suffix = section_count("shelved") .. " shelves"
      end
      if suffix ~= "" then
        local pad = math.max(2, win_width - vim.fn.strdisplaywidth(label) - vim.fn.strdisplaywidth(suffix) - 2)
        table.insert(text_lines, " " .. label .. string.rep(" ", pad) .. suffix)
      else
        table.insert(text_lines, " " .. label)
      end
    elseif row.kind == "info" then
      table.insert(text_lines, string.format("   %-7s %s", row.label .. ":", row.value))
    elseif row.kind == "blank" then
      table.insert(text_lines, "")
    elseif row.kind == "empty" then
      table.insert(text_lines, row.text or "")
    elseif row.kind == "file" then
      local mark = row.checked and "[x]" or "[ ]"
      local dir = compact_directory(row.directory, 30)
      local change = row.section == "opened" and ("[" .. tostring(row.change or "default") .. "]") or ""
      if row.section == "writable" then
        table.insert(text_lines, string.format("%s%s  %s", pointer, mark, row.filename))
      elseif dir ~= "" then
        table.insert(text_lines, string.format("%s%s  %-7s %-10s %-24s %s", pointer, mark, row.status, change, row.filename, dir))
      else
        table.insert(text_lines, string.format("%s%s  %-7s %-10s %s", pointer, mark, row.status, change, row.filename))
      end
    elseif row.kind == "changelist" or row.kind == "shelved" then
      local desc = tostring(row.description or ""):gsub("\n", " "):sub(1, 55)
      table.insert(text_lines, string.format("%sCL %-6d  %s", pointer, row.number, desc))
    elseif row.kind == "changelist_header" then
      table.insert(text_lines, string.format("%s%s", pointer, row.text or ""))
    elseif row.kind == "shelf_header" then
      table.insert(text_lines, string.format("%s%s", pointer, row.text or ""))
    end
  end

  if #text_lines == 0 then
    table.insert(text_lines, "(no data)")
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for i, row in ipairs(rows) do
    local line = i - 1
    local line_text = text_lines[line + 1] or ""
    if row.kind == "section" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSection", line, 0, #line_text)
    elseif row.kind == "info" or row.kind == "empty" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsMuted", line, 0, #line_text)
    elseif row.kind == "file" then
      if i == state.cursor then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSelector", line, 0, 2)
      end
      local mark_begin = line_text:find("%[.%]")
      if mark_begin then
        vim.api.nvim_buf_add_highlight(buf, ns, row.checked and "UVCSVcsChecked" or "UVCSVcsUnchecked", line, mark_begin - 1, mark_begin + 2)
      end
      if row.section ~= "writable" then
        local stat_end = (mark_begin or 0) + 4 + 7
        local sg = "UVCSVcsStatusEdit"
        if row.status == "add" or row.status == "add?" then sg = "UVCSVcsStatusAdd"
        elseif row.status == "delete" or row.status == "delete?" then sg = "UVCSVcsStatusDel"
        elseif row.section == "local" then sg = "UVCSVcsStatusLocal" end
        vim.api.nvim_buf_add_highlight(buf, ns, sg, line, (mark_begin or 0) + 3, math.min(stat_end, #line_text))
      end
      local fn_start = line_text:find(row.filename, 1, true)
      if fn_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsFilename", line, fn_start - 1, fn_start - 1 + #row.filename)
      end
      local compact_dir = compact_directory(row.directory, 30)
      local dir_start = compact_dir ~= "" and line_text:find(compact_dir, 1, true) or nil
      if dir_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsDir", line, dir_start - 1, #line_text)
      end
    elseif row.kind == "changelist" or row.kind == "shelved" then
      if i == state.cursor then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSelector", line, 0, 2)
      end
      local num = tostring(row.number)
      local num_start = line_text:find(num, 1, true)
      if num_start then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsChangelistNum", line, num_start - 1, num_start - 1 + #num)
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsChangelistDesc", line, num_start + #num + 1, #line_text)
      end
    elseif row.kind == "changelist_header" then
      if i == state.cursor then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSelector", line, 0, 2)
      end
      vim.api.nvim_buf_add_highlight(buf, ns, row.expanded and "UVCSVcsFoldOpen" or "UVCSVcsFoldClosed", line, 0, #line_text)
    elseif row.kind == "shelf_header" then
      if i == state.cursor then
        vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSelector", line, 0, 2)
      end
      vim.api.nvim_buf_add_highlight(buf, ns, row.expanded and "UVCSVcsFoldOpen" or "UVCSVcsFoldClosed", line, 0, #line_text)
    end
  end

  if is_selectable(state.rows[state.cursor]) then
    local sel_line = state.cursor - 1
    vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSelected", sel_line, 0, -1)
    pcall(vim.api.nvim_win_set_cursor, state.wins.left_win, { sel_line + 1, 0 })
  end
end

local function set_right_lines(lines, ft)
  if not state or not state.wins then return end
  local buf = state.wins.right_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "uvcs-vcs-detail"
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_win_set_cursor, state.wins.right_win, { 1, 0 })
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = state.wins.right_win })
  pcall(vim.api.nvim_set_option_value, "sidescrolloff", 0, { win = state.wins.right_win })
  pcall(vim.api.nvim_win_call, state.wins.right_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, curswant = 0, leftcol = 0 })
    vim.cmd("normal! 0")
  end)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    if i == 1 then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsSection", lnum, 0, #line)
    elseif line:sub(1, 1) == "+" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsDiffAdd", lnum, 0, #line)
    elseif line:sub(1, 1) == "-" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsDiffDel", lnum, 0, #line)
    elseif line:sub(1, 2) == "@@" then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsDiffHunk", lnum, 0, #line)
    elseif line:match("^%s*File:") or line:match("^%s*Status:") or line:match("^%s*User:") then
      vim.api.nvim_buf_add_highlight(buf, ns, "UVCSVcsMeta", lnum, 0, math.min(#line, 12))
    end
  end
end

local function render_file_summary(item)
  if item.section == "writable" then
    local lines = {
      "File Content / Writable",
      "",
      normalize_path(item.path),
      "",
      "Status: writable? (not opened in P4)",
      "",
      "Press c to checkout (p4 edit).",
      "",
    }
    local ok, content = pcall(vim.fn.readfile, item.path, "", 40)
    if ok and content and #content > 0 then
      table.insert(lines, "")
      table.insert(lines, "-- file content (first 40 lines) --")
      table.insert(lines, "")
      for _, l in ipairs(content) do
        table.insert(lines, l)
      end
    end
    set_right_lines(lines, "uvcs-vcs-detail")
    return
  end
  set_right_lines({
    "Diff / Preview",
    "",
    normalize_path(item.path),
    "",
    "Status: " .. tostring(item.status or ""),
    "",
    "Press d to load diff.",
  }, "uvcs-vcs-detail")
end

local function render_change_summary(item)
  local label = item.kind == "shelved" and "Shelved Change" or "Change"
  set_right_lines({
    "Diff / Preview",
    "",
    label .. " " .. tostring(item.number),
    "User: " .. tostring(item.user or "?"),
    "",
    "Description:",
    "  " .. tostring(item.description or ""),
    "",
    "Press l or Enter to load detail.",
  }, "uvcs-vcs-detail")
end

function load_file_diff(item)
  if not state or not item or not item.path then return end
  if vim.fn.filereadable(item.path) ~= 1 then return end
  if not is_dashboard_file(item.path) then
    state.cache.diff[item.path] = { error = "invalid local file path: " .. tostring(item.path) }
    M.render_right()
    return
  end
  if state.cache.diff[item.path] and state.cache.diff[item.path].text then
    M.render_right()
    return
  end
  state.cache.diff[item.path] = { loading = true }
  M.render_right()
  local token = state.token
  p4.diff_async(item.path, state.root, function(text, err)
    if not state or state.token ~= token then return end
    state.cache.diff[item.path] = err and { error = err } or { text = text or "" }
    M.render_right()
  end)
end

function load_shelf_diff(change_num, file)
  if not state then return end
  local cache_key = "shelf_diff:" .. tostring(change_num)
  if file then
    cache_key = cache_key .. ":" .. vim.fn.fnamemodify(file.path, ":t")
  end
  if state.cache.diff[cache_key] and state.cache.diff[cache_key].text then
    M.render_right()
    return
  end
  state.cache.diff[cache_key] = { loading = true }
  M.render_right()
  local token = state.token
  p4.system_async(p4.p4_cmd("describe", {"-S", "-du", tostring(change_num)}), nil, function(stdout, stderr, code)
    if not state or state.token ~= token then return end
    if code ~= 0 then
      state.cache.diff[cache_key] = { error = (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "shelf diff failed" }
    else
      state.cache.diff[cache_key] = { text = stdout or "" }
    end
    M.render_right()
  end)
end

function M.render_right()
  if not state or not state.wins then return end
  local item = get_current_item()
  if not item then
    set_right_lines({ "Diff / Preview", "", "No selection." }, "uvcs-vcs-detail")
    return
  end

  if item.kind == "file" then
    local cache_key = item.path
    if item.section == "shelf" then
      cache_key = "shelf_diff:" .. tostring(item.shelf_number or 0) .. ":" .. vim.fn.fnamemodify(item.path, ":t")
    end
    local cached = state.cache.diff[cache_key]
    if cached and cached.loading then
      set_right_lines({ "Diff / Preview", "", normalize_path(item.path), "", "Loading diff..." }, "uvcs-vcs-detail")
    elseif cached and cached.error then
      set_right_lines({ "Diff / Preview", "", normalize_path(item.path), "", "Diff failed: " .. tostring(cached.error) }, "uvcs-vcs-detail")
    elseif cached and cached.text then
      local lines = {
        "Diff / Preview",
        "",
        normalize_path(item.path),
        "Status: " .. tostring(item.status or ""),
        "",
      }
      vim.list_extend(lines, vim.split(cached.text, "\n", { plain = true }))
      set_right_lines(lines, "diff")
    else
      if item.section == "shelf" then
        load_shelf_diff(item.shelf_number or 0, item)
      else
        load_file_diff(item)
      end
    end
    return
  end

  if item.kind == "changelist" or item.kind == "shelved" then
    local cache_key = item.kind .. ":" .. tostring(item.number)
    local cached = state.cache.changelist_detail[cache_key]
    if cached and cached.loading then
      set_right_lines({ "Diff / Preview", "", "Change " .. tostring(item.number), "", "Loading detail..." }, "uvcs-vcs-detail")
    elseif cached and cached.error then
      set_right_lines({ "Diff / Preview", "", "Change " .. tostring(item.number), "", "Detail failed: " .. tostring(cached.error) }, "uvcs-vcs-detail")
    elseif cached and cached.detail then
      local detail = cached.detail
      local lines = {
        "Diff / Preview",
        "",
        (item.kind == "shelved" and "Shelved Change " or "Change ") .. tostring(detail.number),
        "User: " .. tostring(detail.user or "?"),
        "Status: " .. tostring(detail.status or ""),
        "",
        "Description:",
        "  " .. tostring(detail.description or ""),
        "",
        "Files:",
      }
      for _, f in ipairs(detail.files or {}) do
        table.insert(lines, "  " .. tostring(f.status or "") .. "  " .. tostring(f.path or ""))
      end
      set_right_lines(lines, "uvcs-vcs-detail")
    else
      render_change_summary(item)
    end
    return
  end

  if item.kind == "changelist_header" then
    local lines = {
      "Diff / Preview",
      "",
      "Changelist",
      "Description: " .. tostring(item.description or ""),
      "ID: " .. tostring(item.change or "default"),
      "Files: " .. tostring(item.file_count or 0),
      "",
    }
    if item.expanded then
      table.insert(lines, "Press Enter to collapse.")
    else
      table.insert(lines, "Press Enter to expand.")
    end
    set_right_lines(lines, "uvcs-vcs-detail")
    return
  end

  if item.kind == "shelf_header" then
    local shelf_diff_key = "shelf_diff:" .. tostring(item.number)
    local shelf_diff = state.cache.diff[shelf_diff_key]
    if shelf_diff and shelf_diff.loading then
      set_right_lines({ "Diff / Preview", "", "Shelf " .. tostring(item.number), "", "Loading diff..." }, "uvcs-vcs-detail")
      return
    elseif shelf_diff and shelf_diff.error then
      set_right_lines({ "Diff / Preview", "", "Shelf " .. tostring(item.number), "", "Diff failed: " .. tostring(shelf_diff.error) }, "uvcs-vcs-detail")
      return
    elseif shelf_diff and shelf_diff.text then
      local lines = { "Diff / Preview", "", "Shelf Diff  CL " .. tostring(item.number), "", "Full shelf diff:", "" }
      vim.list_extend(lines, vim.split(shelf_diff.text, "\n", { plain = true }))
      set_right_lines(lines, "diff")
      return
    end
    local key = tostring(item.number)
    local entry = state.data.shelf_files[key]
    local files = entry and entry.files or {}
    local file_count = type(files) == "table" and #files or 0
    if file_count == 0 and entry and entry.lazy_count then
      file_count = entry.lazy_count
    end
    local lines = {
      "Diff / Preview",
      "",
      "Shelved Changelist",
      "Description: " .. tostring(item.description or ""),
      "ID: " .. tostring(item.number),
      "User: " .. tostring(item.user or "?"),
      "Files: " .. tostring(file_count),
      "",
    }
    if entry and entry.error then
      table.insert(lines, "Failed to load files:")
      table.insert(lines, "  " .. tostring(entry.error))
    elseif item.expanded and not entry then
      table.insert(lines, "Loading shelf files...")
    elseif item.expanded then
      table.insert(lines, "Press Enter to collapse.")
    else
      table.insert(lines, "Press Enter to expand.")
    end
    set_right_lines(lines, "uvcs-vcs-detail")
    return
  end

  set_right_lines({ "Diff / Preview", "", "No preview available." }, "uvcs-vcs-detail")
end

local function render_all(keep_cursor)
  if not state then return end
  local old_item = get_current_item()
  local old_key = old_item and (old_item.path or (old_item.change and old_item.kind .. ":change:" .. old_item.change) or (old_item.kind .. ":" .. tostring(old_item.number))) or nil
  rebuild_rows()
  if keep_cursor and old_key then
    for i, row in ipairs(state.rows) do
      local key = row.path or (row.change and row.kind .. ":change:" .. row.change) or (row.kind .. ":" .. tostring(row.number))
      if key == old_key then
        state.cursor = i
        break
      end
    end
  end
  if not is_selectable(state.rows[state.cursor]) then
    cursor_to_first_selectable()
  end
  M.render_header()
  M.render_left()
  M.render_right()
  M.render_footer()
end

local function load_changelist_detail(item)
  if not state or not item or not item.number then return end
  local cache_key = item.kind .. ":" .. tostring(item.number)
  if state.cache.changelist_detail[cache_key] and state.cache.changelist_detail[cache_key].detail then
    M.render_right()
    return
  end
  state.cache.changelist_detail[cache_key] = { loading = true }
  M.render_right()
  local token = state.token
  local loader = item.kind == "shelved" and p4.shelved_detail_async or p4.changelist_detail_async
  loader(item.number, function(detail, err)
    if not state or state.token ~= token then return end
    state.cache.changelist_detail[cache_key] = err and { error = err } or { detail = detail }
    M.render_right()
  end)
end

local function set_loading_for_filter()
  local filter = state.filter or "all"
  state.loading.info = true
  state.loading.files = filter == "all" or filter == "files"
  state.loading.shelved = filter == "all" or filter == "shelved"
  state.loading.writable = filter == "all" or filter == "files"
end

local function mark_done(section, err)
  if not state then return end
  state.loading[section] = false
  state.data.errors[section] = err
end

local function is_ready()
  return not state.loading.info
      and not state.loading.files
      and not state.loading.shelved
      and not state.loading.writable
end

local function update_ready_status()
  if state and is_ready() then
    state.status = "ready"
  end
end

function M.load_data()
  if not state then return end
  local root = state.root
  local token = state.token
  set_loading_for_filter()
  state.data.info = {}
  state.data.opened = {}
  state.data.local_changes = {}
  state.data.writable_unopened = {}
  state.data.pending = {}
  state.data.shelved = {}
  state.data.shelf_files = {}
  state.data.errors = {}
  state.expanded = {
    changelists = {},
    shelves = {},
  }
  render_all(false)

  p4.info_async(function(info, err)
    if not state or state.token ~= token then return end
    state.data.info = info or {}
    mark_done("info", err and ("p4 info failed: " .. tostring(err)) or nil)
    update_ready_status()
    render_all(true)
  end)

  if state.loading.files then
    local pending_files = 2
    local file_errors = {}
    local function done_files(kind, err)
      if err then table.insert(file_errors, kind .. ": " .. tostring(err)) end
      pending_files = pending_files - 1
      if pending_files == 0 then
        mark_done("files", #file_errors > 0 and table.concat(file_errors, "; ") or nil)
        update_ready_status()
        render_all(true)
      end
    end

    p4.opened_async(root, function(files, err)
      if not state or state.token ~= token then return end
      state.data.opened = vim.tbl_filter(function(file)
        return file and is_dashboard_file(file.path)
      end, files or {})
      done_files("opened", err)
    end)
    p4.status_async(root, function(files, err)
      if not state or state.token ~= token then return end
      state.data.local_changes = vim.tbl_filter(function(file)
        return file and is_dashboard_file(file.path)
      end, files or {})
      done_files("status", err)
    end)
  end

  if state.loading.writable then
    p4.writable_unopened_async(root, function(files, err)
      if not state or state.token ~= token then return end
      state.data.writable_unopened = vim.tbl_filter(function(file)
        return file and is_dashboard_file(file.path)
      end, files or {})
      mark_done("writable", err and ("p4 writable failed: " .. tostring(err)) or nil)
      update_ready_status()
      render_all(true)
    end)
  end

  -- fetch pending changelists for header descriptions (not displayed as section)
  p4.pending_changelists_async(root, function(changes, err)
    if not state or state.token ~= token then return end
    state.data.pending = changes or {}
    update_ready_status()
    render_all(true)
  end)

  if state.loading.shelved then
    p4.shelved_changelists_async(root, function(changes, err)
      if not state or state.token ~= token then return end
      state.data.shelved = changes or {}
      for _, ch in ipairs(state.data.shelved or {}) do
        local key = tostring(ch.number)
        if not state.data.shelf_files[key] then
          p4.shelved_detail_async(ch.number, function(detail, err)
            if not state or state.token ~= token then return end
            if detail and detail.files then
              state.data.shelf_files[key] = { files = {}, loading = false, lazy_count = #detail.files }
            end
            render_all(true)
          end)
        end
      end
      mark_done("shelved", err and ("p4 shelved failed: " .. tostring(err)) or nil)
      update_ready_status()
      render_all(true)
    end)
  end

  update_ready_status()
  render_all(true)
end

local function setup_keymaps()
  if not state or not state.wins then return end
  local buf = state.wins.left_buf
  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "j", function() move_cursor(1) end, opts)
  vim.keymap.set("n", "<Down>", function() move_cursor(1) end, opts)
  vim.keymap.set("n", "k", function() move_cursor(-1) end, opts)
  vim.keymap.set("n", "<Up>", function() move_cursor(-1) end, opts)

  vim.keymap.set("n", " ", function()
    local item = get_current_item()
    if not item or item.kind ~= "file" then return end
    item.checked = not item.checked
    M.render_left()
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    local item = get_current_item()
    if not item then return end
    if item.kind == "file" and item.path and vim.fn.filereadable(item.path) == 1 then
      M.close()
      vim.cmd.edit(vim.fn.fnameescape(item.path))
    elseif item.kind == "changelist_header" then
      state.expanded.changelists[item.change] = not item.expanded
      render_all(true)
    elseif item.kind == "shelf_header" then
      local key = tostring(item.number)
      local was_expanded = item.expanded
      state.expanded.shelves[key] = not was_expanded
      if not was_expanded then
        -- always re-fetch on expand, drop stale cache
        state.data.shelf_files[key] = nil
        local token = state.token
        p4.shelved_detail_async(item.number, function(detail, err)
          if not state or state.token ~= token then return end
          if detail and detail.files then
            local files = {}
            for _, f in ipairs(detail.files or {}) do
              local fpath = f.path or ""
              -- depot path -> local
              if fpath:match("^//") then
                fpath = fpath:gsub("#%d+$", "")
                local local_p = p4.depot_to_local(fpath)
                if local_p then
                  fpath = local_p
                end
              end
              table.insert(files, {
                status = f.status or "edit",
                path = fpath,
                action = f.status or "edit",
              })
            end
            state.data.shelf_files[key] = {
              files = files,
              loading = false,
            }
          else
            state.data.shelf_files[key] = {
              files = {},
              loading = false,
              error = err,
            }
          end
          render_all(true)
        end)
      end
      render_all(true)
    elseif item.kind == "changelist" or item.kind == "shelved" then
      M.enter_drill(item)
    elseif item.kind == "back" then
      M.go_back()
    end
  end, opts)

  vim.keymap.set("n", "d", function()
    local item = get_current_item()
    if item and item.kind == "shelf_header" then
      load_shelf_diff(item.number, nil)
      return
    end
    if not item or item.kind ~= "file" then
      vim.notify("UVCS: move to a file row", vim.log.levels.INFO)
      return
    end
    if not item.path or vim.fn.filereadable(item.path) ~= 1 then
      if item.section == "shelf" then
        load_shelf_diff(item.shelf_number or 0, item)
        return
      end
      vim.notify("UVCS: file not found on disk: " .. tostring(item.path), vim.log.levels.WARN)
      return
    end
    load_file_diff(item)
  end, opts)

  vim.keymap.set("n", "c", function()
    local item = get_current_item()
    if not item or item.kind ~= "file" then
      vim.notify("UVCS: move to a file row", vim.log.levels.INFO)
      return
    end
    if not item.path or vim.fn.filereadable(item.path) ~= 1 then
      vim.notify("UVCS: file not found on disk", vim.log.levels.WARN)
      return
    end
    if item.section == "opened" then
      vim.notify("UVCS: " .. item.filename .. " is already opened", vim.log.levels.INFO)
      return
    end
    if item.section == "writable" then
      -- proceed to checkout writable file
    elseif is_add_candidate(item) then
      vim.notify("UVCS: this looks like a new file. Use 'a' to p4 add it.", vim.log.levels.INFO)
      return
    end
    local ok, err = p4.checkout(item.path, state.root)
    if ok then
      vim.notify("UVCS: p4 edit " .. item.filename, vim.log.levels.INFO)
      M.refresh()
    else
      vim.notify("UVCS: p4 edit failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, opts)

  vim.keymap.set("n", "a", function()
    local item = get_current_item()
    if not item or item.kind ~= "file" then
      vim.notify("UVCS: move to a file row", vim.log.levels.INFO)
      return
    end
    if not is_add_candidate(item) then
      if is_modify_candidate(item) then
        vim.notify("UVCS: modified local files should use 'c' for p4 edit, not add.", vim.log.levels.INFO)
      else
        vim.notify("UVCS: only new local files can be added.", vim.log.levels.INFO)
      end
      return
    end
    local ok, err = p4.add_file(item.path, state.root)
    if ok then
      vim.notify("UVCS: p4 add " .. item.filename, vim.log.levels.INFO)
      M.refresh()
    else
      vim.notify("UVCS: p4 add failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, opts)

  vim.keymap.set("n", "r", function()
    local item = get_current_item()
    if not item or item.kind ~= "file" then
      vim.notify("UVCS: move to a file row", vim.log.levels.INFO)
      return
    end
    if item.section == "writable" then
      vim.notify("UVCS: writable files are not opened in P4. Checkout first with 'c', then revert with 'r'.", vim.log.levels.INFO)
      return
    end
    local loaded_buf = find_loaded_buffer(item.path)
    local has_unsaved_buffer = loaded_buf and vim.api.nvim_buf_is_valid(loaded_buf) and vim.bo[loaded_buf].modified
    local message = "UVCS: revert " .. item.filename .. "?\nThis discards local changes."
    if has_unsaved_buffer then
      message = message .. "\n\nThis file also has unsaved buffer changes; they will be discarded too."
    end
    local confirm = vim.fn.confirm(message, "&Revert\n&Cancel", 2, "Question")
    if confirm ~= 1 then return end
    local ok, err = p4.do_revert(item.path, state.root)
    if ok then
      reload_buffer_from_disk(item.path)
      vim.notify("UVCS: reverted " .. item.filename, vim.log.levels.INFO)
      M.refresh()
    else
      vim.notify("UVCS: revert failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end, opts)

  vim.keymap.set("n", "m", function()
    local checked = {}
    for _, row in ipairs(state.rows) do
      if row.kind == "file" and row.checked then
        table.insert(checked, row.path)
      end
    end
    if #checked == 0 then
      vim.notify("UVCS: no files selected for commit", vim.log.levels.WARN)
      return
    end

    local writable_checked = {}
    for _, row in ipairs(state.rows) do
      if row.kind == "file" and row.checked and row.section == "writable" then
        table.insert(writable_checked, row.filename or row.path)
      end
    end
    if #writable_checked > 0 then
      vim.notify(
        "UVCS: writable files are not opened in P4. Checkout first with 'c':\n  " .. table.concat(writable_checked, "\n  "),
        vim.log.levels.WARN
      )
      return
    end
    local root = state.root
    local dashboard_filter = state.filter
    M.close()
    vim.schedule(function()
      require("uvcs.dirty").confirm_save(root, { action = "commit" }, function(ok)
        if not ok then
          require("uvcs.dashboard").open({ root = root, filter = dashboard_filter })
          return
        end
        require("uvcs.commit").open(root, { files = checked })
      end)
    end)
  end, opts)

  vim.keymap.set("n", "l", function()
    local item = get_current_item()
    if not item or (item.kind ~= "changelist" and item.kind ~= "shelved") then
      vim.notify("UVCS: move to a drill-down changelist row", vim.log.levels.INFO)
      return
    end
    load_changelist_detail(item)
  end, opts)

  vim.keymap.set("n", "s", function()
    local item = get_current_item()
    if not item or item.kind ~= "changelist" then
      vim.notify("UVCS: move to a drill-down changelist row", vim.log.levels.INFO)
      return
    end
    local confirm = vim.fn.confirm(
      "UVCS: submit changelist " .. tostring(item.number) .. "?", "&Submit\n&Cancel", 2, "Question"
    )
    if confirm ~= 1 then return end
    local ok, err = p4.submit_changelist(item.number)
    if ok then
      vim.notify("UVCS: submit successful", vim.log.levels.INFO)
      M.refresh()
    else
      vim.notify("UVCS: submit failed:\n" .. tostring(err), vim.log.levels.ERROR)
    end
  end, opts)

  vim.keymap.set("n", "R", function()
    M.refresh()
  end, opts)

  vim.keymap.set("n", "?", function()
    vim.notify([[
UVCS Dashboard

j/k      Move selection
Space    Toggle file checked
Enter    Open file / toggle changelist or shelf
d        Load diff for selected file
c        p4 edit selected file
a        p4 add selected local candidate
r        Revert selected file (with confirmation)
m        Open commit UI with checked files
l        Show drill-down changelist detail
s        Submit selected pending changelist
R        Refresh data
?        This help
q/Esc    Close dashboard
]], vim.log.levels.INFO)
  end, opts)

  local all_bufs = { state.wins.header_buf, state.wins.left_buf, state.wins.right_buf, state.wins.footer_buf }
  for _, b in ipairs(all_bufs) do
    vim.keymap.set("n", "q", M.close, { buffer = b, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", M.close, { buffer = b, nowait = true, silent = true })
  end

  if autocmd_group then
    pcall(vim.api.nvim_del_augroup_by_id, autocmd_group)
  end
  autocmd_group = vim.api.nvim_create_augroup("UVCSVcsDashboard", { clear = true })
  for _, b in ipairs(all_bufs) do
    vim.api.nvim_create_autocmd("BufWinLeave", {
      group = autocmd_group,
      buffer = b,
      once = true,
      callback = function()
        vim.schedule(function()
          M.close()
        end)
      end,
    })
  end
end

function M.refresh()
  if not state then return end
  state.token = state.token + 1
  state.status = "refreshing..."
  state.cache.diff = {}
  state.cache.changelist_detail = {}
  M.load_data()
end

function M.open(opts)
  opts = opts or {}

  if state then
    local next_filter = opts.filter or state.filter or "all"
    if next_filter ~= state.filter then
      state.cursor = 1
    end
    state.filter = next_filter
    M.refresh()
    return
  end

  local root = opts.root or project.find_project_root()
  if not root then
    vim.notify("UVCS: no Unreal project detected", vim.log.levels.ERROR)
    return
  end

  if not p4.detect(root) then
    vim.notify("UVCS: no P4 provider detected", vim.log.levels.WARN)
    return
  end

  if p4.needs_login() then
    local ok, err = p4.login()
    if not ok then
      vim.notify("UVCS: P4 login failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  state = {
    root = root,
    project_name = vim.fn.fnamemodify(root, ":t"),
    filter = opts.filter or "all",
    rows = {},
    cursor = 1,
    status = "loading...",
    token = 1,
    loading = {},
    data = {
      info = {},
      opened = {},
      local_changes = {},
      writable_unopened = {},
      pending = {},
      shelved = {},
      shelf_files = {},
      errors = {},
    },
    cache = {
      diff = {},
      changelist_detail = {},
    },
    expanded = {
      changelists = {},
      shelves = {},
    },
  }

  local wins = open_windows()
  if not wins then state = nil; return end
  state.wins = wins
  setup_keymaps()
  M.load_data()
end

return M
