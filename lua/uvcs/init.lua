-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/init.lua
-- Purpose: Initialize provider selection and expose the public UVCS API.
-- License: MIT

local config = require("uvcs.config")
local p4 = require("uvcs.p4")
local project = require("uvcs.project")

local M = {}

local detected_cache = {}

-- Return the active VCS configuration block.
-- 返回活动的 VCS 配置块。
local function vcs_config()
	return config.values.vcs or {}
end

-- Return the default provider name exposed by the UVCS facade.
-- 返回 UVCS 外观公开的默认提供程序名称。
function M.name()
	return "p4"
end

-- Detect and cache the provider that should handle one project root.
-- 检测并缓存应处理一个项目根的提供程序。
function M.detect(root)
	if not root or root == "" then
		return nil
	end

	if vcs_config().enable == false then
		return nil
	end

	root = root:gsub("\\", "/")
	if detected_cache[root] ~= nil then
		return detected_cache[root]
	end

	local requested = (vcs_config().provider or "auto"):lower()
	if requested == "p4" or requested == "auto" then
		if p4.detect(root) then
			detected_cache[root] = p4
			return p4
		end
	end

	detected_cache[root] = nil
	return nil
end

-- Clear the cached provider detection results.
-- 清除缓存的提供商检测结果。
function M.clear_cache()
	detected_cache = {}
end

-- Return the opened-file status for one project root.
-- 返回一个项目根目录的打开文件状态。
function M.status(root)
	local provider = M.detect(root)
	if not provider then
		return nil, "no P4 provider detected"
	end

	return provider.opened(root), nil
end

-- Check out one file through the detected provider.
-- 通过检测到的提供程序签出一个文件。
function M.checkout(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return false, "no P4 provider detected"
	end

	return provider.checkout(path)
end

-- Return diff output for one file through the detected provider.
-- 通过检测到的提供程序返回一个文件的差异输出。
function M.diff(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return nil, "no P4 provider detected"
	end

	return provider.diff(path)
end

-- Submit files and message through the detected provider.
-- 通过检测到的提供商提交文件和消息。
function M.commit(root, files, message, opts)
	local provider = M.detect(root)
	if not provider then
		return false, "no P4 provider detected"
	end

	return provider.commit(root, files, message, opts or {})
end

-- Revert the provided files through the detected provider.
-- 通过检测到的提供程序恢复提供的文件。
function M.revert(root, files)
	local provider = M.detect(root)
	if not provider then
		return false, "no P4 provider detected"
	end

	for _, path in ipairs(files or {}) do
		provider.do_revert(path)
	end

	return true, nil
end

-- Detect the provider that owns one filesystem path.
-- 检测拥有一个文件系统路径的提供者。
function M.detect_for_path(path)
	if not path or path == "" then
		return nil
	end

	local root = project.find_project_root(path)
	if not root then
		return nil
	end

	return M.detect(root)
end

-- Return whether one path is a Perforce-controlled read-only file.
-- 返回一个路径是否是 Perforce 控制的只读文件。
function M.is_readonly_p4(path)
	local provider = M.detect_for_path(path)
	if not provider then
		return false
	end

	if vim.fn.filewritable(path) == 1 then
		return false
	end

	if provider.is_opened(path) then
		return false
	end

	return true
end

-- Collect opened and local changes into one provider-neutral list.
-- 将打开的和本地的更改收集到一个与提供商无关的列表中。
function M.collect_changes(root)
	local items = {}
	local seen = {}
	local opened = p4.opened(root)
	local local_changes = p4.status(root)

	for _, file in ipairs(opened or {}) do
		local key = tostring(file.path or ""):lower()
		if not seen[key] then
			seen[key] = true
			table.insert(items, {
				path = file.path,
				status = file.action,
				provider = "P4",
				depot = file.depot,
			})
		end
	end

	for _, file in ipairs(local_changes or {}) do
		local key = tostring(file.path or ""):lower()
		if not seen[key] then
			seen[key] = true
			table.insert(items, {
				path = file.path,
				status = "local",
				provider = "P4",
			})
		end
	end

	return items
end

-- Open the UVCS dashboard with the requested filter.
-- 使用请求的过滤器打开 UVCS 仪表板。
function M.open_dashboard(filter)
	require("uvcs.dashboard").open({ filter = filter or "all" })
end

-- Open the commit UI after confirming dirty buffers are handled.
-- 确认脏缓冲区已处理后打开提交 UI。
function M.open_commit_ui(root, preselected_files)
	root = root or project.find_project_root_from_context()
	if not root then
		vim.notify("UVCS: no Unreal project detected", vim.log.levels.ERROR)
		return
	end

	require("uvcs.dirty").confirm_save(root, { action = "commit" }, function(ok)
		if not ok then
			return
		end

		require("uvcs.commit").open(root, { files = preselected_files })
	end)
end

-- Set up UVCS configuration, commands, and readonly prompts.
-- 初始化 UVCS 配置、命令以及只读文件提示逻辑。
function M.setup(opts)
	config.setup(opts)
	M.reset()
	M.clear_cache()
	require("uvcs.commands").register()

	local current = vcs_config()
	if current.enable == false then
		return
	end

	if current.prompt_on_readonly_save ~= false then
		require("uvcs.readonly").setup()
	end
end

-- Reset registered UVCS commands, UI state, and readonly hooks.
-- 重置已注册的 UVCS 命令、UI 状态和只读挂钩。
function M.reset()
	M.clear_cache()
	pcall(vim.api.nvim_del_user_command, "UVCS")
	pcall(vim.api.nvim_del_augroup_by_name, "UVCSVcsDashboard")
	pcall(function()
		require("uvcs.readonly").reset()
	end)
end

return M
