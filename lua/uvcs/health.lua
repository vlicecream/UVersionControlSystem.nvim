-- Author: Ame林汀
-- Website: vlicecream.github.io
-- File: lua/uvcs/health.lua
-- Purpose: Report UVCS runtime prerequisites and provider status through :checkhealth.
-- License: MIT

local config = require("uvcs.config")
local project = require("uvcs.project")

local M = {}

-- Start one :checkhealth section using the available Neovim health API.
-- 使用可用的 Neovim health API 启动一个 :checkhealth 部分。
local function start(message)
	vim.health.start(message)
end

-- Report one successful health-check message.
-- 报告一条成功的健康检查消息。
local function ok(message)
	vim.health.ok(message)
end

-- Report one informational health-check message.
-- 报告一条信息性健康检查消息。
local function info(message)
	vim.health.info(message)
end

-- Report one warning health-check message with optional advice.
-- 报告一条警告健康检查消息以及可选建议。
local function warn(message, advice)
	vim.health.warn(message, advice)
end

-- Render one boolean value as a human-readable yes-or-no string.
-- 将一个布尔值呈现为人类可读的是或否字符串。
local function yes_no(value)
	return value and "yes" or "no"
end

-- Check UVCS configuration and Perforce prerequisites for the current environment.
-- 检查当前环境的 UVCS 配置和 Perforce 先决条件。
function M.check()
	start("UVCS")

	local values = config.values
	info("enabled: " .. yes_no(values.enable ~= false))
	info("provider: " .. tostring(values.provider or "auto"))
	info("prompt on readonly save: " .. yes_no(values.prompt_on_readonly_save ~= false))

	local p4_cmd = (values.p4 or {}).command or "p4"
	if vim.fn.executable(p4_cmd) == 1 then
		ok("p4 executable found: " .. p4_cmd)
	else
		warn("p4 executable not found: " .. p4_cmd, {
			"Install Perforce CLI or set p4.command in require(\"uvcs\").setup({ p4 = { command = ... } }).",
		})
	end

	local buffer_path = vim.api.nvim_buf_get_name(0)
	info("current buffer: " .. (buffer_path ~= "" and buffer_path or "(none)"))

	local root = buffer_path ~= "" and project.find_project_root(buffer_path) or project.find_project_root_from_context()
	if not root then
		info("open a file inside an Unreal project to test provider detection")
		return
	end

	info("project root: " .. root)
	local provider = require("uvcs").detect(root)
	if provider then
		ok("provider detected: " .. provider.name():upper())
	else
		info("no VCS provider detected for current project")
	end
end

return M
