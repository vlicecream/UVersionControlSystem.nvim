-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/commands.lua
-- Purpose: Implement and dispatch :UVCS user commands.
-- License: MIT

local project = require("uvcs.project")
local uvcs = require("uvcs")

local M = {}

-- Create a scratch buffer for UVCS command output.
-- 为 UVCS 命令输出创建临时缓冲区。
local function scratch(title, lines)
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "uvcs-status"
	pcall(vim.api.nvim_buf_set_name, buf, "uvcs://" .. title:gsub("%s+", "-"):lower() .. "/" .. tostring(buf))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
end

-- Run an interactive Perforce login and report the result.
-- 运行交互式 Perforce 登录并报告结果。
function M.login()
	local ok, result, err = pcall(function()
		return require("uvcs.p4").login()
	end)

	if ok and result ~= false then
		vim.notify("UVCS: P4 login successful", vim.log.levels.INFO)
		return
	end

	local message = ok and (err or "login failed") or result
	vim.notify("UVCS: P4 login failed: " .. tostring(message), vim.log.levels.ERROR)
end

-- Open the UVCS dashboard.
-- 打开 UVCS 仪表板。
function M.dashboard()
	uvcs.open_dashboard("all")
end

-- Return the current buffer path after validating that one file is open.
-- 验证一个文件已打开后返回当前缓冲区路径。
local function current_path()
	local path = vim.api.nvim_buf_get_name(0)
	if path == "" then
		vim.notify("UVCS: no file in current buffer", vim.log.levels.WARN)
		return nil
	end

	return path
end

-- Return the active VCS provider for one path when the command is supported.
-- 当支持该命令时，返回一条路径的活动 VCS 提供程序。
local function current_provider(path)
	local provider = uvcs.detect_for_path(path)
	if not provider then
		vim.notify("UVCS: no VCS provider detected for this file", vim.log.levels.WARN)
		return nil
	end

	if provider.name() ~= "p4" then
		vim.notify("UVCS: command is a no-op for " .. provider.name():upper(), vim.log.levels.INFO)
		return nil
	end

	return provider
end

-- Open the visual commit UI for the current project.
-- 打开当前项目的可视化提交 UI。
function M.commit()
	uvcs.open_commit_ui(nil, nil)
end

-- Check out the current file through the active provider.
-- 通过活动提供程序查看当前文件。
function M.checkout()
	local path = current_path()
	if not path then
		return
	end

	local provider = current_provider(path)
	if not provider then
		return
	end

	local ok, err = provider.checkout(path)
	if ok then
		vim.bo[0].readonly = false
		vim.notify("UVCS: p4 edit " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
	else
		vim.notify("UVCS checkout failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

-- Add the current file through the active provider.
-- 通过活动提供程序添加当前文件。
function M.add()
	local path = current_path()
	if not path then
		return
	end

	local provider = current_provider(path)
	if not provider then
		return
	end

	if not provider.add_file then
		return vim.notify("UVCS: add is not available for this provider", vim.log.levels.WARN)
	end

	local root = project.find_project_root(path)
	local ok, err = provider.add_file(path, root)
	if ok then
		vim.notify("UVCS: p4 add " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
	else
		vim.notify("UVCS add failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

-- Revert the current file after explicit user confirmation.
-- 用户明确确认后恢复当前文件。
function M.revert()
	local path = current_path()
	if not path then
		return
	end

	local provider = current_provider(path)
	if not provider then
		return
	end

	if not provider.do_revert then
		return vim.notify("UVCS: revert is not available for this provider", vim.log.levels.WARN)
	end

	local message = "UVCS: revert " .. vim.fn.fnamemodify(path, ":t") .. "?\n\nThis discards local changes."
	if vim.bo[0].modified then
		message = message .. "\n\nCurrent buffer also has unsaved changes."
	end

	local confirm = vim.fn.confirm(message, "&Revert\n&Cancel", 2, "Warning")
	if confirm ~= 1 then
		return
	end

	local root = project.find_project_root(path)
	local ok, err = provider.do_revert(path, root)
	if ok then
		if vim.api.nvim_buf_is_valid(0) then
			vim.bo[0].readonly = vim.fn.filewritable(path) ~= 1
			pcall(vim.cmd, "checktime")
			if not vim.bo[0].modified and vim.fn.filereadable(path) == 1 then
				pcall(vim.cmd, "silent edit")
			end
		end
		vim.notify("UVCS: reverted " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
	else
		vim.notify("UVCS revert failed: " .. tostring(err), vim.log.levels.ERROR)
	end
end

-- Print the pending changelists for the current Perforce workspace.
-- 打印当前 Perforce 工作区的待处理变更列表。
function M.pending_changelists()
	local buf_path = vim.api.nvim_buf_get_name(0)
	local root = buf_path ~= "" and project.find_project_root(buf_path) or nil
	if not root then
		return vim.notify("UVCS: could not find .uproject", vim.log.levels.ERROR)
	end

	local provider = uvcs.detect(root)
	if not provider or provider.name() ~= "p4" then
		return vim.notify("UVCS: no P4 provider detected", vim.log.levels.WARN)
	end

	if not provider.pending_changelists then
		return vim.notify("UVCS: pending_changelists not available", vim.log.levels.WARN)
	end

	local changes = provider.pending_changelists(root)
	if #changes == 0 then
		return vim.notify("UVCS: no pending changelists", vim.log.levels.INFO)
	end

	print(vim.inspect(changes))
end

-- Open a scratch buffer with current UVCS and Perforce diagnostics.
-- 使用当前 UVCS 和 Perforce 诊断打开临时缓冲区。
function M.debug()
	local path = vim.api.nvim_buf_get_name(0)
	local root = project.find_project_root(path)
	local lines = {
		"UVCS Debug",
		"",
		"Current buffer: " .. (path ~= "" and path or "(none)"),
		"Project root: " .. tostring(root or "(not in Unreal project)"),
	}

	if root then
		local provider = uvcs.detect(root)
		if provider then
			lines[#lines + 1] = "Provider: " .. provider.name():upper()

			if provider.name() == "p4" then
				lines[#lines + 1] = "P4 config source: " .. tostring(provider.config_source())
				lines[#lines + 1] = "P4 command: " .. tostring(provider.p4_cmd("info")[1])

				local info, info_err = provider.info(root)
				if info then
					lines[#lines + 1] = "P4 client: " .. tostring(info["client name"] or "?")
					lines[#lines + 1] = "P4 user: " .. tostring(info["user name"] or "?")
					lines[#lines + 1] = "P4 root: " .. tostring(info["client root"] or "?")
					lines[#lines + 1] = "P4 server: " .. tostring(info["server address"] or "?")
				else
					lines[#lines + 1] = "P4 info: " .. tostring(info_err)
				end

				if path ~= "" then
					lines[#lines + 1] = ""
					lines[#lines + 1] = "Current file:"
					lines[#lines + 1] = "  writable: " .. tostring(vim.fn.filewritable(path) == 1)
					lines[#lines + 1] = "  buffer readonly: " .. tostring(vim.bo[0].readonly)
					lines[#lines + 1] = "  p4 opened: " .. tostring(provider.is_opened(path))
				end

				lines[#lines + 1] = ""
				lines[#lines + 1] = "All opened files:"
				local opened_files = provider.opened(root)
				if #opened_files > 0 then
					for _, file in ipairs(opened_files) do
						lines[#lines + 1] = "  [" .. file.action .. "] " .. file.path
					end
				else
					lines[#lines + 1] = "  (none)"
				end
			end
		else
			lines[#lines + 1] = "Provider: none (not in a VCS workspace)"
		end
	end

	scratch("UVCS Debug", lines)
end

-- Print the main :UVCS help text.
-- 打印 :UVCS 主帮助文本。
function M.help()
	print([[
UVCS commands:

  :UVCS              Open VCS dashboard
  :UVCS dashboard    Open VCS dashboard
  :UVCS checkout     Checkout current file (p4 edit)
  :UVCS add          Add current file (p4 add)
  :UVCS revert       Revert current file (p4 revert)
  :UVCS commit       Open visual commit UI
  :UVCS debug        Debug subcommands
  :UVCS help         Show this help
]])
end

-- Print the :UVCS debug help text.
-- 打印 :UVCS debug 子命令的帮助文本。
function M.debug_help()
	print([[
UVCS debug commands:

  :UVCS debug vcs         Print VCS diagnostics
  :UVCS debug help        Show this help
]])
end

-- Split one command string into the first token and remaining tail.
-- 将一个命令字符串拆分为第一个标记和剩余的尾部。
local function split_first(text)
	local head, tail = (text or ""):match("^%s*(%S*)%s*(.-)%s*$")
	if head == "" then
		return "help", ""
	end

	return head:lower(), tail or ""
end

-- Dispatch one UVCS debug subcommand.
-- 调度一个 UVCS 调试子命令。
local function dispatch_debug(tail)
	local sub = split_first(tail)
	local handlers = {
		help = M.debug_help,
		vcs = M.debug,
	}

	local handler = handlers[sub]
	if not handler then
		vim.notify("Unknown UVCS debug command: " .. tostring(sub), vim.log.levels.ERROR)
		return M.debug_help()
	end

	handler()
end

-- Dispatch one :UVCS command invocation.
-- 调度一：UVCS 命令调用。
function M.dispatch(args)
	local input = args.args or ""
	if vim.trim(input) == "" then
		return M.dashboard()
	end

	local sub, tail = split_first(input)
	local handlers = {
		help = M.help,
		dashboard = M.dashboard,
		checkout = M.checkout,
		add = M.add,
		revert = M.revert,
		commit = M.commit,
		debug = function()
			dispatch_debug(tail)
		end,
	}

	local handler = handlers[sub]
	if not handler then
		vim.notify("Unknown UVCS command: " .. sub, vim.log.levels.ERROR)
		return M.help()
	end

	handler()
end

-- Register the :UVCS user command and its completion handler.
-- 注册 :UVCS 用户命令及其完成处理程序。
function M.register()
	pcall(vim.api.nvim_del_user_command, "UVCS")

	vim.api.nvim_create_user_command("UVCS", M.dispatch, {
		nargs = "*",
		complete = function(arglead, cmdline, cursorpos)
			local user_items = {
				"dashboard",
				"checkout",
				"add",
				"revert",
				"commit",
				"debug",
				"help",
			}
			local debug_items = {
				"vcs",
				"help",
			}

			local line = cmdline or ""
			local before_cursor = line:sub(1, (cursorpos or (#line + 1)) - 1)
			local tail = before_cursor:match("^%s*UVCS%s*(.-)%s*$") or ""
			local first = tail:match("^(%S+)")
			local items = first and first:lower() == "debug" and debug_items or user_items
			local needle = (arglead or ""):lower()

			if first and first:lower() == "debug" and tail:lower():match("^debug%s*$") then
				needle = ""
			end

			return vim.tbl_filter(function(item)
				return item:find(needle, 1, true) == 1
			end, items)
		end,
	})
end

return M
