-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/project.lua
-- Purpose: Resolve Unreal project roots and project files for UVCS commands.
-- License: MIT

local M = {}

-- Normalize one filesystem path to forward-slash form.
-- 将一个文件系统路径规范为正斜杠形式。
local function normalize(path)
	return path and path:gsub("\\", "/") or nil
end

-- Search upward from one path until a .uproject file is found.
-- 从一个路径向上搜索，直到找到 .uproject 文件。
function M.find_project_file(start_path)
	start_path = start_path or vim.api.nvim_buf_get_name(0)

	if start_path == "" then
		start_path = vim.loop.cwd()
	end

	if start_path == "" then
		return nil
	end

	local dir
	if vim.fn.isdirectory(start_path) == 1 then
		dir = start_path
	else
		dir = vim.fn.fnamemodify(start_path, ":p:h")
	end

	local found = vim.fs.find(function(name)
		return name:match("%.uproject$")
	end, {
		path = dir,
		upward = true,
		type = "file",
		limit = 1,
	})[1]

	return found and normalize(found) or nil
end

-- Return the project root directory for one path inside an Unreal project.
-- 返回虚幻项目内一个路径的项目根目录。
function M.find_project_root(start_path)
	local project_file = M.find_project_file(start_path)
	if not project_file then
		return nil
	end

	return normalize(vim.fn.fnamemodify(project_file, ":p:h"))
end

-- Resolve the active project root from the current editor context.
-- 从当前编辑器上下文解析活动项目根。
function M.find_project_root_from_context()
	local buf_path = vim.api.nvim_buf_get_name(0)
	if buf_path and buf_path ~= "" then
		local root = M.find_project_root(buf_path)
		if root then
			return root
		end
	end

	local cwd = vim.loop.cwd()
	if cwd then
		local root = M.find_project_root(cwd)
		if root then
			return root
		end
	end

	local alt = vim.fn.bufnr("#")
	if alt and alt > 0 then
		local alt_path = vim.api.nvim_buf_get_name(alt)
		if alt_path and alt_path ~= "" then
			local root = M.find_project_root(alt_path)
			if root then
				return root
			end
		end
	end

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local bo = vim.bo[bufnr]
		if bo.buflisted and bo.buftype == "" and bo.modifiable then
			local path = vim.api.nvim_buf_get_name(bufnr)
			if path and path ~= "" then
				local root = M.find_project_root(path)
				if root then
					return root
				end
			end
		end
	end

	return nil
end

return M
