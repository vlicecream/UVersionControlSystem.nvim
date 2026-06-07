-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/p4.lua
-- Purpose: Wrap Perforce commands, parsing, and asynchronous workflows for the UVCS provider.
-- License: MIT

local config = require("uvcs.config")

local M = {}

-- Sanitize one string before passing it into a Perforce command.
-- 在将字符串传递到 Perforce 命令之前对其进行清理。
local function sanitize(path)
  if not path then return "" end
  return tostring(path):gsub("\0", "")
end

-- Convert one path to Windows separators for Perforce tools that expect native paths.
-- 对于需要本机路径的 Perforce 工具，将一个路径转换为 ​​Windows 分隔符。
local function win_path(path)
  return (sanitize(path):gsub("/", "\\"))
end

-- Return whether one file argument looks unsafe to pass to Perforce.
-- 返回一个文件参数是否看起来不安全，无法传递给 Perforce。
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

-- Return whether one executable is available on PATH.
-- 返回 PATH 上是否有一个可执行文件可用。
local function executable(name)
  return vim.fn.executable(name) == 1
end

-- Prompt for hidden input through the command line.
-- 通过命令行提示隐藏输入。
local function prompt_secret_input(title, default)
  title = tostring(title or "Input")
  default = tostring(default or "")

  vim.fn.inputsave()
  local ok, result
  if default ~= "" then
    ok, result = pcall(vim.fn.inputsecret, title .. ": ", default)
  else
    ok, result = pcall(vim.fn.inputsecret, title .. ": ")
  end
  vim.fn.inputrestore()

  if not ok then
    return nil
  end
  return result
end

-- Prompt for hidden input through the best available async UI.
-- 通过最佳可用的异步 UI 提示隐藏输入。
local function prompt_secret_input_async(title, default, callback)
  title = tostring(title or "Input")
  default = tostring(default or "")

  local ok_ui, ui = pcall(require, "ucore.ui.select")
  if ok_ui and type(ui) == "table" and type(ui.input) == "function" then
    local ok_input = pcall(ui.input, {
      title = title,
      default = default,
      secret = true,
    }, callback)
    if ok_input then
      return
    end
  end

  vim.ui.input({ prompt = title .. ": ", default = default }, callback)
end

-- Return the first meaningful error line from stdout or stderr.
-- 从 stdout 或 stderr 返回第一个有意义的错误行。
local function first_error_line(stdout, stderr, fallback)
  local text = stderr ~= "" and stderr or stdout
  return tostring(text or ""):match("[^\r\n]+") or fallback
end

-- Return whether one Perforce error message indicates an expired or missing login.
-- 返回一条 Perforce 错误消息是否指示登录已过期或丢失。
local function is_login_error(text)
  text = tostring(text or ""):lower()
  if text == "" then
    return false
  end

  return text:find("not logged in", 1, true) ~= nil
      or text:find("session has expired", 1, true) ~= nil
      or text:find("password invalid", 1, true) ~= nil
      or text:find("p4passwd invalid or unset", 1, true) ~= nil
      or text:find("ticket has expired", 1, true) ~= nil
      or text:find("your session has expired", 1, true) ~= nil
end

-- Run one Perforce operation and retry after login when authentication expired.
-- 运行一项 Perforce 操作，并在身份验证过期后登录后重试。
local function run_with_login_retry(op)
  -- Centralize login recovery here so every sync command gets the same
  -- ticket-expiry behavior instead of duplicating retry logic at each callsite.
  if M.needs_login() then
    local login_ok, login_err = M.login()
    if not login_ok then
      return false, login_err
    end
  end

  local ok, err = op()
  if ok then
    return true, err
  end

  if not is_login_error(err) then
    return false, err
  end

  local login_ok, login_err = M.login()
  if not login_ok then
    return false, login_err or err
  end

  return op()
end

-- Return the provider name for the Perforce backend.
-- 返回 Perforce 后端的提供者名称。
function M.name()
  return "p4"
end

-- Build the environment overrides used for Perforce commands.
-- 构建用于 Perforce 命令的环境覆盖。
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

-- Return whether the user configured explicit Perforce overrides.
-- 返回用户是否配置了显式 Perforce 覆盖。
function M.has_user_overrides()
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  return vcs_p4.port ~= nil
      or vcs_p4.user ~= nil
      or vcs_p4.client ~= nil
      or vcs_p4.charset ~= nil
      or vcs_p4.config ~= nil
      or (vcs_p4.env ~= nil and next(vcs_p4.env) ~= nil)
end

-- Return whether Perforce config comes from user overrides or ambient environment.
-- 返回 Perforce 配置是否来自用户覆盖或周围环境。
function M.config_source()
  if M.has_user_overrides() then
    return "user override"
  end
  return "default environment"
end

-- Build a sanitized p4 command with one subcommand and extra arguments.
-- 使用一个子命令和额外参数构建一个经过清理的 p4 命令。
function M.p4_cmd(subcommand, args)
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  local cmd = { vcs_p4.command or "p4", subcommand }
  for _, a in ipairs(args or {}) do
    cmd[#cmd + 1] = sanitize(a)
  end
  return cmd
end

-- Build a raw p4 command without sanitizing the provided arguments.
-- 构建原始 p4 命令而不清理提供的参数。
local function p4_raw_cmd(args)
  local vcs_p4 = (config.values.vcs or {}).p4 or {}
  local cmd = { vcs_p4.command or "p4" }
  for _, a in ipairs(args or {}) do
    cmd[#cmd + 1] = a
  end
  return cmd
end

-- Merge Perforce environment overrides into one vim.system options table.
-- 将 Perforce 环境覆盖合并到一个 vim.system 选项表中。
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

-- Parse `p4 info` output into a keyed table.
-- 将“p4 info”输出解析到键控表中。
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

-- Parse `p4 changes` output into changelist entries.
-- 将“p4 Changes”输出解析为更改列表条目。
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

-- Normalize one changelist identifier into a stable string key.
-- 将一个变更列表标识符规范化为稳定的字符串键。
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

-- Parse the changelist identifier reported by one opened-file line.
-- 解析由打开的文件行报告的更改列表标识符。
local function parse_opened_change(line, fallback)
  local change = line:match("%-%s+%S+%s+change%s+(%d+)")
      or line:match("%-%s+%S+%s+(%d+)%s+change")
      or line:match("%-%s+%S+%s+(default%s+change)")
      or fallback
  return normalize_change_id(change)
end

-- Parse describe output into a structured changelist detail table.
-- 将描述输出解析为结构化变更列表详细信息表。
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

-- Return the default Perforce pathspec for one project root.
-- 返回一个项目根目录的默认 Perforce 路径规范。
local function root_pathspec(root)
  return (root or "."):gsub("/", "\\") .. "\\..."
end

-- Join path segments with normalized separators.
-- 使用标准化分隔符连接路径段。
local function join_path(...)
  return table.concat(vim.tbl_map(function(part)
    return tostring(part or ""):gsub("[/\\]+$", ""):gsub("^[/\\]+", "")
  end, { ... }), "/")
end

-- Collect the project pathspecs that currently exist on disk.
-- 收集磁盘上当前存在的项目路径规范。
local function existing_pathspecs(root)
  if not root or root == "" then
    return { root_pathspec(root) }
  end

  local specs = {}
  local normalized_root = root:gsub("[/\\]+$", "")

  -- Add one directory pathspec when it exists in the project tree.
  -- 如果项目目录树里存在该目录，则添加对应的目录 pathspec，同时避免扫描整个工作区。
  local function add_dir(relative)
    local path = join_path(normalized_root, relative)
    if vim.fn.isdirectory(path) == 1 then
      specs[#specs + 1] = win_path(path) .. "\\..."
    end
  end

  -- Add one file to Perforce.
  -- 将一个文件添加到 Perforce。
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
    -- Fall back to the broad project root only when none of the expected roots exist.
    specs[#specs + 1] = root_pathspec(root)
  end

  return specs
end

-- Normalize one filesystem path to forward-slash form.
-- 将一个文件系统路径规范为正斜杠形式。
local function normalize_path(path)
  return tostring(path or ""):gsub("\\", "/")
end

-- Return whether one path already uses Perforce depot syntax.
-- 返回一个路径是否已使用 Perforce depot 语法。
local function is_depot_path(path)
  return type(path) == "string" and path:match("^//") ~= nil
end

-- Return whether one path resolves to a real local file under the project root.
-- 返回一个路径是否解析为项目根目录下的真实本地文件。
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

-- Return whether one path belongs to the active project and can be managed by Perforce.
-- 返回一个路径是否属于活动项目并且可以由 Perforce 管理。
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

-- Return one project-relative path for the provided file.
-- 返回所提供文件的一个项目相对路径。
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

-- Return whether one reconcile result should stay visible in the dashboard.
-- 返回一项协调结果是否应在仪表板中保持可见。
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

-- Normalize one local file path returned by Perforce.
-- 标准化 Perforce 返回的一个本地文件路径。
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

-- Resolve the best local filesystem path for one reconcile status line.
-- 解析一个协调状态行的最佳本地文件系统路径。
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

-- Translate raw reconcile text into the dashboard action label.
-- 把原始 reconcile 文本转换成仪表盘使用的动作标签。
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

-- Parse reconcile preview output into local file change entries.
-- 将协调预览输出解析为本地文件更改条目。
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

-- Run a reconcile preview for one project root with the provided flags.
-- 使用提供的标志对一个项目根运行协调预览。
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

-- Run a reconcile preview asynchronously for one project root.
-- 为一个项目根异步运行协调预览。
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

-- Normalize one async vim.system result before invoking the callback.
-- 在调用回调之前标准化一个异步 vim.system 结果。
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

-- Run one command asynchronously with the configured Perforce environment.
-- 使用已配置的 Perforce 环境异步运行一个命令。
function M.system_async(cmd, stdin, cb)
  local opts = apply_env({ text = true })
  if stdin then
    opts.stdin = stdin
  end
  vim.system(cmd, opts, async_result(cmd, cb))
end

-- Run one command synchronously with the configured Perforce environment.
-- 与配置的 Perforce 环境同步运行一个命令。
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

-- Run one command synchronously and return parsed success and error text.
-- 同步运行一个命令并返回解析的成功和错误文本。
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

-- Detect whether Perforce is available for one project root.
-- 检测 Perforce 是否可用于一个项目根目录。
function M.detect(root)
  if not executable(config.values.vcs.p4.command or "p4") then
    return false
  end
  local result = M.system(M.p4_cmd("info", {"-s"}))
  return vim.v.shell_error == 0
end

-- Return parsed `p4 info` data for one project root.
-- 返回一个项目根的解析后的“p4 info”数据。
function M.info(root)
  local result = M.system(M.p4_cmd("info", {"-s"}))
  if vim.v.shell_error ~= 0 then
    return nil, "p4 info failed"
  end
  return parse_info(result), nil
end

-- Return the Perforce client root reported by `p4 info`.
-- 返回“p4 info”报告的 Perforce 客户端根目录。
function M.client_root()
  local info, err = M.info()
  if not info then
    return nil, err
  end
  return info["client root"], nil
end

-- Return whether one path is already opened in Perforce.
-- 返回一条路径是否已在 Perforce 中打开。
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

-- Return the files currently opened in Perforce for one project root.
-- 返回当前在 Perforce 中为一个项目根打开的文件。
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

-- Return local reconcile status entries for one project root.
-- 返回一个项目根的本地协调状态条目。
function M.status(root)
  local files, _stdout, _stderr, code = reconcile_preview(root, {"-a", "-d"})
  if code ~= 0 then
    return {}
  end
  return files
end

-- Check out one file in Perforce.
-- 在 Perforce 中查看一个文件。
function M.checkout(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return false, "file not found: " .. path
  end
  return run_with_login_retry(function()
    local stdout, stderr, code = M.system_err(M.p4_cmd("edit", {win_path(path)}))
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "p4 edit failed")
    end
    return true, nil
  end)
end

-- Run an asynchronous Perforce login flow.
-- 以异步方式执行一次 Perforce 登录流程。
function M.login_async(callback)
  prompt_secret_input_async("P4 password", "", function(password)
    if not password or password == "" then
      callback(false, "password is empty")
      return
    end

    M.system_async(M.p4_cmd("login"), password .. "\n", function(stdout, stderr, code)
      if code ~= 0 then
        callback(false, first_error_line(stdout, stderr, "login failed"))
        return
      end
      callback(true, nil)
    end)
  end)
end

-- Ensure an async Perforce session is logged in before continuing.
-- 确保异步 Perforce 会话已登录，然后再继续。
function M.ensure_login_async(callback)
  M.system_async(M.p4_cmd("login", {"-s"}), nil, function(stdout, stderr, code)
    if code == 0 then
      callback(true, nil)
      return
    end
    M.login_async(callback)
  end)
end

-- Check out one file asynchronously through Perforce.
-- 通过 Perforce 异步检出一个文件。
function M.checkout_async(path, root, callback)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    callback(true, nil)
    return
  end
  if vim.fn.filereadable(path) ~= 1 then
    callback(false, "file not found: " .. path)
    return
  end

  -- Run one checkout attempt and optionally retry after login.
  -- 运行一次结帐尝试，并可选择在登录后重试。
  local function edit_once(retried)
    M.system_async(M.p4_cmd("edit", {win_path(path)}), nil, function(stdout, stderr, code)
      if code == 0 then
        callback(true, nil)
        return
      end

      local err = first_error_line(stdout, stderr, "p4 edit failed")
      if not retried and is_login_error((stderr or "") .. "\n" .. (stdout or "")) then
        M.login_async(function(login_ok, login_err)
          if not login_ok then
            callback(false, login_err or err)
            return
          end
          edit_once(true)
        end)
        return
      end

      callback(false, err)
    end)
  end

  M.ensure_login_async(function(login_ok, login_err)
    if not login_ok then
      callback(false, login_err)
      return
    end
    edit_once(false)
  end)
end

-- Return diff output for one file from Perforce.
-- 从 Perforce 返回一个文件的差异输出。
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

-- Translate one depot path into the corresponding local client path.
-- 将一个软件仓库路径转换为相应的本地客户端路径。
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

-- Make one file writable without necessarily opening it in Perforce.
-- 使一个文件可写，而不必在 Perforce 中打开它。
function M.make_writable(path)
  if vim.fn.has("win32") == 1 then
    vim.fn.system({"attrib", "-R", win_path(path)})
  else
    vim.fn.system({"chmod", "u+w", path})
  end
  return vim.v.shell_error == 0
end

-- Create a new Perforce changelist with the provided description.
-- 使用提供的描述创建新的 Perforce 变更列表。
function M.create_changelist(description)
  local change_num
  local ok, err = run_with_login_retry(function()
    local spec = M.system(M.p4_cmd("changelist", {"-o"}))
    if vim.v.shell_error ~= 0 then
      return false, first_error_line(spec, "", "failed to read changelist spec")
    end
    local new_spec = spec:gsub("<enter description here>", description or "(no description)")
    local stdout, stderr, code = M.system_err(M.p4_cmd("changelist", {"-i"}), new_spec)
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "failed to create changelist")
    end
    change_num = stdout:match("Change (%d+)")
    if not change_num then
      return false, "could not parse changelist number"
    end
    return true, nil
  end)

  if not ok then
    return nil, err
  end

  return tonumber(change_num), nil
end

-- Move one file into the requested Perforce changelist.
-- 将一个文件移至请求的 Perforce 更改列表中。
function M.reopen_file(path, change_num)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, nil)
  if suspicious then
    return true, nil
  end
  return run_with_login_retry(function()
    local stdout, stderr, code = M.system_err(M.p4_cmd("reopen", {"-c", tostring(change_num), win_path(path)}))
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "reopen failed")
    end
    return true, nil
  end)
end

-- Submit one Perforce changelist.
-- 提交一份 Perforce 变更列表。
function M.submit_changelist(change_num)
  return run_with_login_retry(function()
    local stdout, stderr, code = M.system_err(M.p4_cmd("submit", {"-c", tostring(change_num)}))
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "submit failed")
    end
    return true, stdout
  end)
end

-- Submit the provided files and message through Perforce.
-- 通过 Perforce 提交提供的文件和消息。
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

-- Revert one file in Perforce.
-- 在 Perforce 中恢复一个文件。
function M.do_revert(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if vim.fn.filereadable(path) ~= 1 then
    return false, "file not found: " .. path
  end
  return run_with_login_retry(function()
    local stdout, stderr, code = M.system_err(M.p4_cmd("revert", {win_path(path)}))
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "p4 revert failed")
    end
    return true, nil
  end)
end

-- Add one file to Perforce.
-- 将一个文件添加到 Perforce。
function M.add_file(path, root)
  path = sanitize(path)
  local suspicious = is_suspicious_file_arg(path, root)
  if suspicious then
    return true, nil
  end
  if not is_real_local_path(path, root) then
    return false, "invalid local file path: " .. path
  end
  return run_with_login_retry(function()
    local stdout, stderr, code = M.system_err(M.p4_cmd("add", {win_path(path)}))
    if code ~= 0 then
      return false, first_error_line(stdout, stderr, "p4 add failed")
    end
    return true, nil
  end)
end

-- Return parsed detail data for one pending changelist.
-- 返回一个待处理变更列表的已解析详细数据。
function M.changelist_detail(change_num)
  local result = M.system(M.p4_cmd("describe", {"-s", tostring(change_num)}))
  if vim.v.shell_error ~= 0 then
    return nil, "failed to describe changelist " .. tostring(change_num)
  end
  return parse_describe_output(result, change_num, ""), nil
end

-- Return whether the current Perforce session requires login.
-- 返回当前 Perforce 会话是否需要登录。
function M.needs_login()
  local result = M.system(M.p4_cmd("login", {"-s"}))
  return vim.v.shell_error ~= 0
end

-- Run a synchronous Perforce login flow.
-- 以同步方式执行一次 Perforce 登录流程。
function M.login(password)
  local pwd = password
  if not pwd then
    pwd = prompt_secret_input("P4 password")
  end
  if not pwd or pwd == "" then
    return false, "password is empty"
  end
  local stdout, stderr, code = M.system_err(M.p4_cmd("login"), pwd .. "\n")
  if code ~= 0 then
    local err = first_error_line(stdout, stderr, "login failed")
    return false, err
  end
  return true, nil
end

-- Return shelved changelists visible from one project root.
-- 返回从一个项目根目录可见的搁置变更列表。
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

-- Return pending changelists visible from one project root.
-- 返回从一个项目根可见的待定变更列表。
function M.pending_changelists(root)
  local info = M.info()
  return M.pending_changelists_with_info(root, info)
end

-- Return pending changelists using pre-fetched `p4 info` data.
-- 使用预取的“p4 info”数据返回挂起的更改列表。
function M.pending_changelists_with_info(root, info)
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

-- Return whether the current buffer session is running with allwrite enabled.
-- 返回当前缓冲区会话是否在启用 allwrite 的情况下运行。
local function allwrite_enabled()
  local result = M.system(M.p4_cmd("client", {"-o"}))
  if vim.v.shell_error ~= 0 then return false end
  return result:match("allwrite") and not result:match("noallwrite")
end

-- Return writable project files that are not opened in Perforce.
-- 返回未在 Perforce 中打开的可写项目文件。
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

-- Return writable unopened project files asynchronously.
-- 异步返回可写的未打开的项目文件。
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

-- Return parsed detail data for one shelved changelist.
-- 返回一个搁置变更列表的已解析详细数据。
function M.shelved_detail(change_num)
  local result = M.system(M.p4_cmd("describe", {"-S", tostring(change_num)}))
  if vim.v.shell_error ~= 0 then
    return nil, "failed to describe shelved changelist " .. tostring(change_num)
  end
  return parse_describe_output(result, change_num, "shelved"), nil
end

-- Load `p4 info` data asynchronously.
-- 异步加载`p4 info`数据。
function M.info_async(cb)
  M.system_async(M.p4_cmd("info", {"-s"}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 info failed")
      return
    end
    cb(parse_info(stdout), nil)
  end)
end

-- Load opened-file data asynchronously for one project root.
-- 为一个项目根异步加载打开的文件数据。
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

-- Load local reconcile status asynchronously for one project root.
-- 异步加载一个项目根的本地协调状态。
function M.status_async(root, cb)
  reconcile_preview_async(root, {"-a", "-d"}, function(parsed, stdout, stderr, code)
    if code ~= 0 then
      cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 reconcile failed")
      return
    end

    cb(parsed, nil)
  end)
end

-- Load pending changelists asynchronously for one project root.
-- 为一个项目根异步加载挂起的变更列表。
function M.pending_changelists_async(root, cb)
  M.info_async(function(info, err)
    if err then
      M.pending_changelists_with_info_async(root, nil, cb)
      return
    end
    M.pending_changelists_with_info_async(root, info, cb)
  end)
end

-- Load shelved changelists asynchronously for one project root.
-- 为一个项目根异步加载搁置的变更列表。
function M.shelved_changelists_async(root, cb)
  M.info_async(function(info, err)
    if err then
      M.shelved_changelists_with_info_async(root, nil, cb)
      return
    end
    M.shelved_changelists_with_info_async(root, info, cb)
  end)
end

-- Load pending changelists asynchronously using pre-fetched info data.
-- 使用预取的信息数据异步加载挂起的更改列表。
function M.pending_changelists_with_info_async(root, info, cb)
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
end

-- Load shelved changelists asynchronously using pre-fetched info data.
-- 使用预取的信息数据异步加载搁置的变更列表。
function M.shelved_changelists_with_info_async(root, info, cb)
  local user = info and info["user name"]
  local args = user and {"-s", "shelved", "-u", user} or {"-s", "shelved"}
  M.system_async(M.p4_cmd("changes", args), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb({}, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or "p4 shelved changes failed")
      return
    end
    local changes = parse_changes(stdout)
    if #changes == 0 and user then
      M.system_async(M.p4_cmd("changes", {"-s", "shelved"}), nil, function(stdout2, _stderr2, code2)
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
end

-- Load diff output asynchronously for one file.
-- 异步加载一个文件的 diff 输出。
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

-- Load pending changelist detail asynchronously.
-- 异步加载挂起的变更列表详细信息。
function M.changelist_detail_async(change_num, cb)
  M.system_async(M.p4_cmd("describe", {"-s", tostring(change_num)}), nil, function(stdout, stderr, code)
    if code ~= 0 then
      cb(nil, (stderr ~= "" and stderr or stdout):match("[^\r\n]+") or ("failed to describe changelist " .. tostring(change_num)))
      return
    end

    cb(parse_describe_output(stdout, change_num, ""), nil)
  end)
end

-- Load shelved changelist detail asynchronously.
-- 异步加载搁置的变更列表详细信息。
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
