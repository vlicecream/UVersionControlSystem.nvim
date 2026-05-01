local config = require("uvcs.config")
local project = require("uvcs.project")

local M = {}

local function start(message)
	vim.health.start(message)
end

local function ok(message)
	vim.health.ok(message)
end

local function info(message)
	vim.health.info(message)
end

local function warn(message, advice)
	vim.health.warn(message, advice)
end

local function yes_no(value)
	return value and "yes" or "no"
end

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
