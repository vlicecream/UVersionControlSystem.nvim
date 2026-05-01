local config = require("uvcs.config")

local M = {}

local function sanitize(path)
  if not path then return "" end
  return tostring(path):gsub("\0", "")
end

local function win_path(path)
  return (sanitize(path):gsub("/", "\\"))
end

local function is_suspicious_file_arg(path, root)
  path = sanitize(path)
  if path == "" or path == "0" or path:match("[/\\]0$") then
    return true, "zero-or-empty-path"
  end
  if path:match("^%a+://") then
    return true, "uri-path"
  end
  return false, nil
end

local function executable(name)
  return vim.fn.executable(name) == 1
end

function M.name()
  return "p4"
end

function M.build_env()
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  local env = {}

  if vcs_p4.env and type(vcs_p4.env) == "table" then
    for k, v in pairs(vcs_p4.env) do
      env[k] = tostring(v)
    end
  end

  if vcs_p4.port then
    env.P4PORT = tostring(vcs_p4.port)
  end
  if vcs_p4.user then
    env.P4USER = tostring(vcs_p4.user)
  end
  if vcs_p4.client then
    env.P4CLIENT = tostring(vcs_p4.client)
  end
  if vcs_p4.charset then
    env.P4CHARSET = tostring(vcs_p4.charset)
  else
    env.P4CHARSET = "utf8"
  end
  if vcs_p4.config then
    env.P4CONFIG = tostring(vcs_p4.config)
  end

  return env
end

function M.has_user_overrides()
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  return vcs_p4.port ~= nil
      or vcs_p4.user ~= nil
      or vcs_p4.client ~= nil
      or vcs_p4.charset ~= nil
      or vcs_p4.config ~= nil
      or (vcs_p4.env ~= nil and next(vcs_p4.env) ~= nil)
end

function M.config_source()
  if M.has_user_overrides() then
    return "user override"
  end
  return "default environment"
end

function M.p4_cmd(subcommand, args)
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  local cmd = { vcs_p4.command or "p4", subcommand }
  for _, a in ipairs(args or {}) do
    cmd[#cmd + 1] = sanitize(a)
  end
  return cmd
end

local function p4_raw_cmd(args)
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  local cmd = { vcs_p4.command or "p4" }
  for _, a in ipairs(args or {}) do
    cmd[#cmd + 1] = a
  end
  return cmd
end

local function apply_env(opts)
  local env = M.build_env()
  if next(env) == nil then
    return opts
  end

  local merged = vim.deepcopy(vim.env)
  for k, v in pairs(env) do
    merged[k] = v
  end
  opts.env = merged
  return opts
end

local function parse_info(result)
  local info = {}
  for line in tostring(result or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^(.-):%s*(.*)$")
    if key and value then
      info[key:lower()] = value
    end
  end
  return info
end

local function parse_changes(result)
  local changes = {}
  for line in tostring(result or ""):gmatch("[^\r\n]+") do
    local num = line:match("^Change (%d+)")
    if num then
      local user = line:match(" by ([^@%s]+)@")
      if user then
        local desc = line:match("'(.*)'%s*$")
        table.insert(changes, {
          number = tonumber(num),
          user = user,
          description = desc ~= nil and desc or "",
        })
      end
    end
  end
  return changes
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

  local number = lowered:match("^change%s+(%d+)$") or lowered:match("^(%d+)%s+change$")
  if number then
    return number
  end

  return change
end

local function parse_opened_change(line, fallback)
  local change = line:match("%-%s+%S+%s+change%s+(%d+)")
      or line:match("%-%s+%S+%s+(%d+)%s+change")
      or line:match("%-%s+%S+%s+(default%s+change)")
      or fallback
  return normalize_change_id(change)
end

local function parse_describe_output(result, change_num, default_status)
  local detail = {
    number = tonumber(change_num),
    user = "",
    description = "",
    files = {},
    status = default_status or "",
  }
  local desc_lines = {}
  local in_description = false
  local saw_change_header = false
  local before_files = true

  for line in tostring(result or ""):gmatch("[^\r\n]+") do
    local header_user = line:match("^Change%s+%d+%s+by%s+([^@%s]+)@")
    if header_user then
      detail.user = header_user
      saw_change_header = true
      goto continue
    end

    local user = line:match("^User:%s*(.+)$")
    if user then detail.user = user end

    local status_tag = line:match("^Status:%s*(.+)$")
    if status_tag then detail.status = status_tag end

    local inline_desc = line:match("^Description:%s*(.*)$")
    if inline_desc ~= nil then
      in_description = true
      inline_desc = vim.trim(inline_desc)
      if inline_desc ~= "" then
        table.insert(desc_lines, inline_desc)
      end
      goto continue
    end

    if line:match("^Affected files") or line:match("^Shelved files") then
      in_description = false
      before_files = false
      goto continue
    end

    if in_description then
      if line:match("^%S") then
        in_description = false
      else
        local desc = vim.trim(line)
        if desc ~= "" then
          table.insert(desc_lines, desc)
        end
        goto continue
      end
    end

    if saw_change_header and before_files then
      local desc = vim.trim(line)
      if desc ~= "" and not desc:match("^%.%.%.") then
        table.insert(desc_lines, desc)
      end
      goto continue
    end

    local depot, rev_action = line:match("^%.%.%.%s+(%S+)%s+(.+)$")
    if depot and rev_action then
      local action = rev_action:match("#%d+%s+(%S+)") or rev_action:match("^(%S+)")
      table.insert(detail.files, { status = action or "", path = depot })
    end

    ::continue::
  end

  detail.description = table.concat(desc_lines, " ")
  return detail
end

local function root_pathspec(root)
  return (root or "."):gsub("/", "\\") .. "\\..."
end

local function join_path(...)
  return table.concat(vim.tbl_map(function(part)
    return tostring(part or ""):gsub("[/\\]+$", ""):gsub("^[/\\]+", "")
  end, { ... }), "/")
end

local function existing_pathspecs(root)
  if not root or root == "" then
    return { root_pathspec(root) }
  end

  local specs = {}
  local normalized_root = root:gsub("[/\\]+$", "")

  local function add_dir(relative)
    local path = join_path(normalized_root, relative)
    if vim.fn.isdirectory(path) == 1 then
      specs[#specs + 1] = win_path(path) .. "\\..."
    end
  end

  local function add_file(path)
    if vim.fn.filereadable(path) == 1 then
      specs[#specs + 1] = win_path(path)
    end
  end

  add_dir("Source")
  add_dir("Config")
  add_dir("Content")

  for _, uproject in ipairs(vim.fn.glob(normalized_root .. "/*.uproject", false, true)) do
    add_file(uproject)
  end

  local plugins_root = join_path(normalized_root, "Plugins")
  if vim.fn.isdirectory(plugins_root) == 1 then
    for _, plugin_dir in ipairs(vim.fn.glob(plugins_root .. "/*", false, true)) do
      if vim.fn.isdirectory(plugin_dir) == 1 then
        add_dir(plugin_dir:sub(#normalized_root + 2) .. "/Source")
        add_dir(plugin_dir:sub(#normalized_root + 2) .. "/Config")
        add_dir(plugin_dir:sub(#normalized_root + 2) .. "/Content")
        for _, uplugin in ipairs(vim.fn.glob(plugin_dir .. "/*.uplugin", false, true)) do
          add_file(uplugin)
        end
      end
    end
  end

  if #specs == 0 then
    specs[#specs + 1] = root_pathspec(root)
  end

  return specs
end

local function normalize_path(path)
  return tostring(path or ""):gsub("\\", "/")
end

local function is_depot_path(path)
  return type(path) == "string" and path:match("^//") ~= nil
end

local function is_real_local_path(path, root)
  path = tostring(path or "")
  if not path or path == "" or path == "0" or path:match("[/\\]0$") then
    return false
  end
  if path:match("^%a+://") then
    return false
  end
  if path:match("^//") or path:find("//", 1, true) then
    return false
  end
  if path:find(" to add ", 1, true) or path:find(" to edit ", 1, true) then
    return false
  end

  local normalized = normalize_path(path)
  if normalized:match("^%a:/") then
    if not root then
      return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
    end
    local normalized_root = normalize_path(root):lower():gsub("/+$", "")
    local normalized_path = normalize_path(normalized):lower()
    return normalized_path == normalized_root or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
  end
  return root ~= nil and not normalized:match("^%.%.")
end

function M.is_project_file(path, root)
  return is_real_local_path(path, root)
end

local RECONCILE_EXCLUDED_DIRS = {
  [".git"] = true,
  [".svn"] = true,
  [".p4"] = true,
  [".vs"] = true,
  [".idea"] = true,
  [".vscode"] = true,
  ["binaries"] = true,
  ["build"] = true,
  ["deriveddatacache"] = true,
  ["intermediate"] = true,
  ["saved"] = true,
}

local RECONCILE_EXCLUDED_EXTS = {
  a = true,
  cache = true,
  db = true,
  dll = true,
  dylib = true,
  exe = true,
  exp = true,
  idb = true,
  ilk = true,
  ipch = true,
  lib = true,
  log = true,
  obj = true,
  o = true,
  pdb = true,
  pch = true,
  so = true,
  sqlite = true,
  suo = true,
  tmp = true,
}

local RECONCILE_EXCLUDED_PATTERNS = {
  "%.sln%.dotsettings%.user$",
  "%.user$",
}

local function relative_project_path(path, root)
  if not root then return nil end
  local normalized_root = normalize_path(root):lower():gsub("/+$", "")
  local normalized_path = normalize_path(path)
  local lowered_path = normalized_path:lower()
  if lowered_path == normalized_root then
    return ""
  end
  if lowered_path:sub(1, #normalized_root + 1) ~= normalized_root .. "/" then
    return nil
  end
  return normalized_path:sub(#normalized_root + 2)
end

local function should_keep_reconcile_file(path, root)
  if not is_real_local_path(path, root) then
    return false
  end

  local relative = relative_project_path(path, root)
  if not relative or relative == "" then
    return false
  end

  local lower = normalize_path(relative):lower()
  for segment in lower:gmatch("[^/]+") do
    if RECONCILE_EXCLUDED_DIRS[segment] then
      return false
    end
  end

  local ext = lower:match("%.([^%.]+)$")
  if ext and RECONCILE_EXCLUDED_EXTS[ext] then
    return false
  end

  for _, pattern in ipairs(RECONCILE_EXCLUDED_PATTERNS) do
    if lower:match(pattern) then
      return false
    end
  end

  return true
end

function M.normalize_local_file(path, root)
  path = sanitize(path)
  if not is_real_local_path(path, root) then
    return nil
  end
  if path:gsub("\\", "/"):match("^%a:/") then
    return path
  end
  if not root then
    return nil
  end
  return (root:gsub("[/\\]+$", "") .. "/" .. path):gsub("/", "\\")
end

local function resolve_local_status_path(path, root)
  path = vim.trim(tostring(path or "")):gsub("#%d+$", "")
  if not is_real_local_path(path, root) then
    return nil
  end
  if path:gsub("\\", "/"):match("^%a:/") then
    return path
  end
  return (root:gsub("[/\\]+$", "") .. "/" .. path):gsub("/", "\\")
end

local function reconcile_action_from_text(text)
  text = tostring(text or ""):lower()
  if text:find("edit", 1, true) then
    return "edit"
  end
  if text:find("add", 1, true) then
    return "add"
  end
  if text:find("delete", 1, true) or text:find("deleted", 1, true) then
    return "delete"
  end
  return "reconcile"
end

local function parse_reconcile_output(result, root)
  local files = {}
  for line in tostring(result or ""):gmatch("[^\r\n]+") do
    local raw = vim.trim(line)
    if raw ~= "" then
      local file_part, action_text = raw:match("^(.-)%s+%-%s+(.+)$")
      local path = file_part or raw
      path = path:gsub("#%d+$", "")

      local local_path
      if is_depot_path(path) then
        local_path = M.depot_to_local(path)
      else
        local_path = resolve_local_status_path(path, root)
      end

      if local_path and should_keep_reconcile_file(local_path, root) then
        local action = reconcile_action_from_text(action_text or raw)
        table.insert(files, {
          path = local_path,
          status = action == "add" and "?" or "m",
          action = action,
          reconcile = true,
          raw = raw,
        })
      end
    end
  end
  return files
end

local function reconcile_preview(root, flags)
  local args = {"-n"}
  for _, flag in ipairs(flags or {}) do
    args[#args + 1] = flag
  end
  vim.list_extend(args, existing_pathspecs(root))

  local cmd = M.p4_cmd("reconcile", args)
  local stdout, stderr, code = M.system_err(cmd)
  local parsed = code == 0 and parse_reconcile_output(stdout, root) or {}
  return parsed, stdout, stderr, code
end

local function reconcile_preview_async(root, flags, cb)
  local args = {"-n"}
  for _, flag in ipairs(flags or {}) do
    args[#args + 1] = flag
  end
  vim.list_extend(args, existing_pathspecs(root))

  local cmd = M.p4_cmd("reconcile", args)
  M.system_async(cmd, nil, function(stdout, stderr, code)
    local parsed = code == 0 and parse_reconcile_output(stdout, root) or {}
    cb(parsed, stdout, stderr, code)
  end)
end

local function async_result(cmd, cb)
  return function(result)
    vim.schedule(function()
      local stdout = result.stdout or ""
      local stderr = result.stderr or ""
      local code = result.code or 0
      cb(stdout, stderr, code)
    end)
  end
end

function M.system_async(cmd, stdin, cb)
  local opts = apply_env({ text = true })
  if stdin then
    opts.stdin = stdin
  end
  vim.system(cmd, opts, async_result(cmd, cb))
end

function M.system(cmd)
  local env = M.build_env()
  if next(env) == nil then
    local result = vim.fn.system(cmd)
    return result
  end
  local saved = {}
  for k, v in pairs(env) do
    saved[k] = vim.env[k]
    vim.env[k] = v
  end
  local result = vim.fn.system(cmd)
  for k, v in pairs(saved) do
    vim.env[k] = v
  end
  return result
end

function M.system_err(cmd, stdin)
  local opts = { text = true }
  if stdin then opts.stdin = stdin end
  local env = M.build_env()
  if next(env) == nil then
    local r = vim.system(cmd, opts):wait()
    return r.stdout or "", r.stderr or "", r.code
  end
  local merged = vim.deepcopy(vim.env)
  for k, v in pairs(env) do
    merged[k] = v
  end
  opts.env = merged
  local r = vim.system(cmd, opts):wait()
  return r.stdout or "", r.stderr or "", r.code
end

function M.detect(root)
  if not executable(config.values.vcs.p4.command or "p4") then
    return false
  end
  local result = M.system(M.p4_cmd("info", {"-s"}))
  return vim.v.shell_error == 0
end

function M.info(root)
  local result = M.system(M.p4_cmd("info", {"-s"}))
  if vim.v.shell_error ~= 0 then
    return nil, "p4 info failed"
  end
  return parse_info(result), nil
end

function M.client_root()
  local info, err = M.info()
  if not info then
    return nil, err
  end
  return info["client root"], nil
end

function M.is_opened(path)
  path = sanitize(path)
  local result = M.system(M.p4_cmd("opened", {win_path(path)}))
  if vim.v.shell_error ~= 0 or result == "" then
    return false
  end

  for line in result:gmatch("[^\r\n]+") do
    -- Real opened records look like:
    -- //depot/path/File.cpp#3 - edit default change (...)
    -- P4 can also print diagnostic text for unopened files, so do not treat
    -- any non-empty output as opened.
    if line:match("^//.-#%d+%s+%-%s+%S+") then
      return true
    end
  end

  return false
end

function M.opened(root)
  local args = {}
  if root then
    args[#args + 1] = root_pathspec(root)
  end
  local result = M.system(M.p4_cmd("opened", args))
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local files = {}
  for line in result:gmatch("[^\r\n]+") do
    local depot_rev, action = line:match("^(%S+)%s*%-%s*(%S+)")
    if depot_rev and action then
      local depot_file = depot_rev:gsub("#%d+$", "")
      local local_path = M.depot_to_local(depot_file)
      if local_path and is_real_local_path(local_path, root) then
        local change = parse_opened_change(line, "default")
        table.insert(files, {
          path = local_path,
          action = action,
          depot = depot_file,
          change = change,
        })
      end
    end
  end
  return files
end

function M.status(root)
  local files, _stdout, _stderr, code = reconcile_preview(root, {"-a", "-d"})
  if code ~= 0 then
    return {}
  end
  return files
end

function M.checkout(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return false, "file not found: " .. path
  end
  local stdout, stderr, code = M.system_err(M.p4_cmd("edit", {win_path(path)}))
  if code ~= 0 then
    local msg = (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 edit failed"
    return false, msg
  end
  return true, nil
end

function M.diff(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return "", nil
  end
  if not is_real_local_path(path, root) then
    return nil, "invalid local file path: " .. tostring(path)
  end
  local result = M.system(M.p4_cmd("diff", {"-f", "-du", win_path(path)}))
  if vim.v.shell_error ~= 0 then
    return nil, "p4 diff failed"
  end
  return result, nil
end

function M.depot_to_local(depot_file)
  if not is_depot_path(depot_file) then
    return nil
  end
  local result = M.system(M.p4_cmd("where", {depot_file}))
  if vim.v.shell_error ~= 0 then
    return nil
  end
  for line in result:gmatch("[^\r\n]+") do
    local parts = vim.split(line, " ")
    if #parts >= 3 then
      return parts[#parts]
    end
  end
  return nil
end

function M.make_writable(path)
  if vim.fn.has("win32") == 1 then
    vim.fn.system({"attrib", "-R", win_path(path)})
  else
    vim.fn.system({"chmod", "u+w", path})
  end
  return vim.v.shell_error == 0
end

function M.create_changelist(description)
  local spec = M.system(M.p4_cmd("changelist", {"-o"}))
  if vim.v.shell_error ~= 0 then
    return nil, "failed to read changelist spec"
  end
  local new_spec = spec:gsub("<enter description here>", description or "(no description)")
  local stdout, stderr, code = M.system_err(M.p4_cmd("changelist", {"-i"}), new_spec)
  if code ~= 0 then
    local msg = (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "failed to create changelist"
    return nil, msg
  end
  local change_num = stdout:match("Change (%d+)")
  if not change_num then
    return nil, "could not parse changelist number"
  end
  return tonumber(change_num), nil
end

function M.reopen_file(path, change_num)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, nil)
  if suspicious then
    return true, nil
  end
  local stdout, stderr, code = M.system_err(M.p4_cmd("reopen", {"-c", tostring(change_num), win_path(path)}))
  if code ~= 0 then
    return false, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "reopen failed"
  end
  return true, nil
end

function M.submit_changelist(change_num)
  local stdout, stderr, code = M.system_err(M.p4_cmd("submit", {"-c", tostring(change_num)}))
  if code ~= 0 then
    return false, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "submit failed"
  end
  return true, stdout
end

function M.commit(root, files, message, opts)
  local change_num, err = M.create_changelist(message)
  if not change_num then
    return false, "create changelist failed: " .. tostring(err)
  end

  local reopen_errs = {}
  for _, raw_path in ipairs(files or {}) do
    local ok, reopen_err = M.reopen_file(raw_path, change_num)
    if not ok then
      table.insert(reopen_errs, vim.fn.fnamemodify(tostring(raw_path or "?"), ":t") .. ": " .. tostring(reopen_err))
    end
  end

  if #reopen_errs > 0 then
    local msg = "reopen failed (changelist " .. tostring(change_num) .. " kept):\n" .. table.concat(reopen_errs, "\n")
    msg = msg .. "\n\nRun :UVCS dashboard and open Pending Changelists"
    return false, msg
  end

  local ok, result = M.submit_changelist(change_num)
  if not ok then
    local msg = "submit failed (changelist " .. tostring(change_num) .. " kept):\n" .. tostring(result)
    msg = msg .. "\n\nRun :UVCS dashboard and open Pending Changelists"
    return false, msg
  end

  return true, result
end

function M.do_revert(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return false, "file not found: " .. path
  end
  local stdout, stderr, code = M.system_err(M.p4_cmd("revert", {win_path(path)}))
  if code ~= 0 then
    return false, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 revert failed"
  end
  return true, nil
end

function M.add_file(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if not is_real_local_path(path, root) then
    return false, "invalid local file path: " .. path
  end
  local stdout, stderr, code = M.system_err(M.p4_cmd("add", {win_path(path)}))
  if code ~= 0 then
    local msg = (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 add failed"
    return false, msg
  end
  return true, nil
end

function M.changelist_detail(change_num)
  local result = M.system(M.p4_cmd("describe", {"-s", tostring(change_num)}))
  if vim.v.shell_error ~= 0 then
    return nil, "failed to describe changelist " .. tostring(change_num)
  end
  return parse_describe_output(result, change_num, ""), nil
end

function M.needs_login()
  local result = M.system(M.p4_cmd("login", {"-s"}))
  return vim.v.shell_error ~= 0
end

function M.login(password)
  local ok = pcall(vim.fn.inputsave)
  local pwd = password
  if not pwd then
    pwd = vim.fn.inputsecret("P4 password: ")
  end
  if ok then pcall(vim.fn.inputrestore) end
  if pwd == "" then
    return false, "password is empty"
  end
  local result = vim.fn.system(M.p4_cmd("login"), pwd)
  if vim.v.shell_error ~= 0 then
    local err = result:match("[^\r\n]+") or "login failed"
    return false, err
  end
  return true, nil
end

function M.shelved_changelists(root)
  local info = M.info()
  local user = info and info["user name"]
  local args = user and {"-s", "shelved", "-u", user} or {"-s", "shelved"}
  local result = M.system(M.p4_cmd("changes", args))
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local changes = parse_changes(result)
  if #changes == 0 and user then
    result = M.system(M.p4_cmd("changes", {"-s", "shelved"}))
    if vim.v.shell_error == 0 then
      changes = parse_changes(result)
    end
  end
  return changes
end

function M.pending_changelists(root)
  local info = M.info()
  local client = info and info["client name"]
  local user = info and info["user name"]
  local args = {"-s", "pending"}
  if client and client ~= "" then
    vim.list_extend(args, {"-c", client})
  end
  if user and user ~= "" then
    vim.list_extend(args, {"-u", user})
  end
  if not client or client == "" then
    args[#args + 1] = root_pathspec(root)
  end

  local cmd = M.p4_cmd("changes", args)
  local result = M.system(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return parse_changes(result)
end

local function allwrite_enabled()
  local result = M.system(M.p4_cmd("client", {"-o"}))
  if vim.v.shell_error ~= 0 then return false end
  return result:match("allwrite") and not result:match("noallwrite")
end

function M.writable_unopened(root)
  if not root then return {} end
  if allwrite_enabled() then return {} end
  local files, _stdout, _stderr, code = reconcile_preview(root, {"-e"})
  if code ~= 0 then return {} end

  local writable = {}
  for _, file in ipairs(files or {}) do
    if file.action == "edit" then
      table.insert(writable, {
        path = file.path,
        status = "writable?",
        action = "writable?",
        raw = file.raw,
      })
    end
  end
  return writable
end

function M.writable_unopened_async(root, cb)
  reconcile_preview_async(root, {"-e"}, function(files, stdout, stderr, code)
    if code ~= 0 then
      cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 reconcile edit failed")
      return
    end

    local writable = {}
    for _, file in ipairs(files or {}) do
      if file.action == "edit" then
        table.insert(writable, {
          path = file.path,
          status = "writable?",
          action = "writable?",
          raw = file.raw,
        })
      end
    end
    cb(writable, nil)
  end)
end

function M.shelved_detail(change_num)
  local result = M.system(M.p4_cmd("describe", {"-S", tostring(change_num)}))
  if vim.v.shell_error ~= 0 then
    return nil, "failed to describe shelved changelist " .. tostring(change_num)
  end
  return parse_describe_output(result, change_num, "shelved"), nil
end

function M.info_async(cb)
  M.system_async(M.p4_cmd("info", {"-s"}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 info failed")
      return
    end
    cb(parse_info(stdout), nil)
  end)
end

function M.opened_async(root, cb)
  local path = root and root_pathspec(root) or nil
  local args = {"-F", "%clientFile%|%action%|%depotFile%|%change%", "opened"}
  if path then
    args[#args + 1] = path
  end

  M.system_async(p4_raw_cmd(args), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 opened failed")
      return
    end

    local files = {}
    for line in stdout:gmatch("[^\r\n]+") do
      local client_file, action, depot, change = line:match("^(.-)|([^|]+)|([^|]*)|(.*)$")
      if not client_file then
        local depot_rev, opened_action = line:match("^(%S+)%s*%-%s*(%S+)")
        if depot_rev and opened_action then
          depot = depot_rev:gsub("#%d+$", "")
          action = opened_action
          change = parse_opened_change(line, "default")
        end
      end
      if (not client_file or not is_real_local_path(client_file, root)) and is_depot_path(depot) then
        client_file = M.depot_to_local(depot)
      end
      if client_file and action and is_real_local_path(client_file, root) then
        if not change or change == "" or change == "0" then
          change = "default"
        end
        change = normalize_change_id(change)
        table.insert(files, {
          path = client_file,
          action = action,
          depot = depot,
          change = change,
        })
      end
    end
    cb(files, nil)
  end)
end

function M.status_async(root, cb)
  reconcile_preview_async(root, {"-a", "-d"}, function(parsed, stdout, stderr, code)
    if code ~= 0 then
      cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 reconcile failed")
      return
    end

    cb(parsed, nil)
  end)
end

function M.pending_changelists_async(root, cb)
  M.info_async(function(info)
    local client = info and info["client name"]
    local user = info and info["user name"]
    local args = {"-s", "pending"}
    if client and client ~= "" then
      vim.list_extend(args, {"-c", client})
    end
    if user and user ~= "" then
      vim.list_extend(args, {"-u", user})
    end
    if not client or client == "" then
      args[#args + 1] = root_pathspec(root)
    end

    local cmd = M.p4_cmd("changes", args)
    M.system_async(cmd, nil, function(stdout, stderr, code)
      if code ~= 0 then
        cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 pending changes failed")
        return
      end
      cb(parse_changes(stdout), nil)
    end)
  end)
end

function M.shelved_changelists_async(root, cb)
  M.info_async(function(info, err)
    local user = info and info["user name"]
    local args = user and {"-s", "shelved", "-u", user} or {"-s", "shelved"}
    M.system_async(M.p4_cmd("changes", args), nil, function(stdout, stderr, code)
      if code ~= 0 then
        cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 shelved changes failed")
        return
      end
      local changes = parse_changes(stdout)
      if #changes == 0 and user then
        M.system_async(M.p4_cmd("changes", {"-s", "shelved"}), nil, function(stdout2, stderr2, code2)
          if code2 == 0 then
            cb(parse_changes(stdout2), nil)
          else
            cb(changes, nil)
          end
        end)
      else
        cb(changes, nil)
      end
    end)
  end)
end

function M.diff_async(path, root, cb)
  if type(root) == "function" then
    local old_cb = root
    vim.schedule(function()
      old_cb(nil, "internal error: p4.diff_async requires project root")
    end)
    return
  end
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    vim.schedule(function()
      cb("", nil)
    end)
    return
  end
  path = M.normalize_local_file(path, root)
  if not path then
    vim.schedule(function()
      cb(nil, nil)
    end)
    return
  end
  path = win_path(path)
  M.system_async(M.p4_cmd("diff", {"-f", "-du", path}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 diff failed")
      return
    end
    cb(stdout, nil)
  end)
end

function M.changelist_detail_async(change_num, cb)
  M.system_async(M.p4_cmd("describe", {"-s", tostring(change_num)}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or ("failed to describe changelist " .. tostring(change_num)))
      return
    end

    cb(parse_describe_output(stdout, change_num, ""), nil)
  end)
end

function M.shelved_detail_async(change_num, cb)
  M.system_async(M.p4_cmd("describe", {"-S", tostring(change_num)}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or ("failed to describe shelved changelist " .. tostring(change_num)))
      return
    end

    cb(parse_describe_output(stdout, change_num, "shelved"), nil)
  end)
end

return M
