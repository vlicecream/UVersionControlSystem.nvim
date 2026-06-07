-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/readonly.lua
-- Purpose: Prompt for checkout when editing Perforce-controlled read-only files.
-- License: MIT

local config = require("uvcs.config")
local vcs = require("uvcs")

local M = {}

local group_name = "UVCSReadonlySave"
local preflight_keys = { "i", "I", "a", "A", "o", "O", "s", "S", "c", "C" }

-- Refresh the UVCS dashboard when readonly state changes may affect it.
-- 当只读状态更改可能影响 UVCS 仪表板时，刷新 UVCS 仪表板。
local function refresh_dashboard()
  vim.schedule(function()
    local ok_m, dashboard = pcall(require, "uvcs.dashboard")
    if ok_m and dashboard and dashboard.refresh then
      dashboard.refresh()
    end
  end)
end

-- Prompt for the action that should happen when a read-only file is edited.
-- 提示编辑只读文件时应执行的操作。
local function prompt_readonly_file(path, action_label)
  local fname = vim.fn.fnamemodify(path, ":t")
  return vim.fn.confirm(
    "UVCS: read-only P4 file\n\n" .. fname .. "\n\nChoose how to " .. action_label .. ":",
    "&P4 checkout/edit\n&Make writable only\n&Cancel",
    1,
    "Warning"
  )
end

-- Apply the selected readonly-handling choice for one buffer and path.
-- 将选定的只读处理选项应用于一个缓冲区和路径。
local function apply_readonly_choice(buf, path, choice, project_root, already_opened)
  if choice == 1 then
    local p4 = require("uvcs.p4")
    if already_opened then
      p4.make_writable(path)
      vim.bo[buf].readonly = false
      vim.notify("UVCS: file already checked out, made writable", vim.log.levels.INFO)
      refresh_dashboard()
      return true
    end

    local ok, err = p4.checkout(path, project_root)
    if ok then
      vim.bo[buf].readonly = false
      vim.notify("UVCS: p4 edit " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
      refresh_dashboard()
      return true
    end
    vim.notify("UVCS: p4 edit failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  elseif choice == 2 then
    local p4 = require("uvcs.p4")
    p4.make_writable(path)
    vim.bo[buf].readonly = false
    vim.notify("UVCS: made writable only (not opened in P4)", vim.log.levels.INFO)
    refresh_dashboard()
    return true
  end

  return false
end

-- Make a file writable when Perforce already has it opened.
-- 当 Perforce 已经打开该文件时，把它切换为可写状态。
local function make_already_opened_writable(buf, path)
  local p4 = require("uvcs.p4")
  p4.make_writable(path)
  vim.bo[buf].readonly = false
  vim.notify("UVCS: file already checked out, made writable", vim.log.levels.INFO)
  refresh_dashboard()
end

-- Return whether UVCS should intercept edits to one read-only file.
-- 返回 UVCS 是否应拦截对一个只读文件的编辑。
local function should_prompt_for_readonly(buf, path)
  if vim.bo[buf].buftype ~= "" or path == "" then
    return false, nil
  end
  if not vim.bo[buf].readonly and vim.fn.filewritable(path) == 1 then
    return false, nil
  end

  local project_root = require("uvcs.project").find_project_root(path)
  if not project_root then
    return false, nil
  end
  local provider = vcs.detect(project_root)
  if not provider then
    return false, nil
  end

  local already_opened = false
  if provider.is_opened then
    already_opened = provider.is_opened(path)
  end

  return true, project_root, already_opened
end

-- Feed one normal-mode key back into Neovim after readonly interception.
-- 只读拦截后，将一个正常模式密钥反馈回 Neovim。
local function feed_normal_key(key)
  local term = vim.api.nvim_replace_termcodes(key, true, false, true)
  vim.api.nvim_feedkeys(term, "n", false)
end

-- Register readonly interception autocmds and key handlers.
-- 注册只读拦截自动命令和按键处理程序。
function M.setup()
  local vcs_config = config.values.vcs or {}
  if vcs_config.enable == false or vcs_config.prompt_on_readonly_save == false then
    return
  end

  local group = vim.api.nvim_create_augroup(group_name, { clear = true })

  if not vim.g.uvcs_readonly_preflight_keymaps then
    vim.g.uvcs_readonly_preflight_keymaps = true
    for _, key in ipairs(preflight_keys) do
      vim.keymap.set("n", key, function()
        local buf = vim.api.nvim_get_current_buf()
        local path = vim.api.nvim_buf_get_name(buf)
        local should_prompt, project_root, already_opened = should_prompt_for_readonly(buf, path)
        if not should_prompt then
          feed_normal_key(key)
          return
        end

        if already_opened then
          make_already_opened_writable(buf, path)
          feed_normal_key(key)
          return
        end

        local choice = prompt_readonly_file(path, "edit")
        if apply_readonly_choice(buf, path, choice, project_root, already_opened) then
          feed_normal_key(key)
        else
          vim.bo[buf].readonly = true
        end
      end, {
        noremap = true,
        silent = true,
        desc = "UVCS readonly edit preflight",
      })
    end
  end

  vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    pattern = "*",
    callback = function(ev)
      local buf = ev.buf
      local path = vim.api.nvim_buf_get_name(buf)

      if vim.bo[buf].buftype ~= "" or path == "" then return end
      if not vim.bo[buf].modified then
        return
      end

      if vim.bo[buf].readonly == false and vim.fn.filewritable(path) == 1 then
        return
      end

      local should_prompt, project_root, already_opened = should_prompt_for_readonly(buf, path)
      if not should_prompt then
        if vim.bo[buf].readonly then
          vim.bo[buf].readonly = false
        end
        return
      end
      if already_opened then
        make_already_opened_writable(buf, path)
        return
      end

      local choice = prompt_readonly_file(path, "save")
      if not apply_readonly_choice(buf, path, choice, project_root, already_opened) then
        vim.notify("UVCS: save cancelled, buffer still has unsaved changes", vim.log.levels.WARN)
        error("UVCS: save cancelled", 0)
      end
    end,
  })

  local prompted = {}
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    pattern = "*",
    callback = function(ev)
      local buf = ev.buf
      if prompted[buf] then return end

      local path = vim.api.nvim_buf_get_name(buf)
      local should_prompt, project_root, already_opened = should_prompt_for_readonly(buf, path)
      if not should_prompt then return end

      if already_opened then
        make_already_opened_writable(buf, path)
        return
      end

      prompted[buf] = true
      local choice = prompt_readonly_file(path, "edit")
      if not apply_readonly_choice(buf, path, choice, project_root, already_opened) then
        prompted[buf] = nil
        vim.bo[buf].readonly = true
        vim.schedule(function()
          if vim.api.nvim_get_current_buf() == buf then
            vim.cmd("stopinsert")
          end
        end)
      end
    end,
  })
end

-- Remove readonly interception autocmds and clear transient state.
-- 移除只读拦截相关的 autocmd，并清理临时状态。
function M.reset()
  pcall(vim.api.nvim_del_augroup_by_name, group_name)
  vim.g.uvcs_readonly_preflight_keymaps = nil
  for _, key in ipairs(preflight_keys) do
    local info = vim.fn.maparg(key, "n", false, true)
    if type(info) == "table" and tostring(info.desc or "") == "UVCS readonly edit preflight" then
      pcall(vim.keymap.del, "n", key)
    end
  end
end

return M
